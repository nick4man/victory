# frozen_string_literal: true

require 'net/http'
require 'json'
require 'securerandom'

module Telegram
  module WorkBot
    # Phase 7.1 — Голосовая транскрипция Telegram-сообщений через Groq Whisper.
    #
    # Pipeline:
    #   1. download .ogg/.oga из TG в Tempfile (Telegram::Client#download_file)
    #   2. multipart POST в Groq /openai/v1/audio/transcriptions
    #      (модель whisper-large-v3-turbo по умолчанию)
    #   3. parse verbose_json → text + segments[].avg_logprob
    #   4. compute confidence = AVG(avg_logprob); low_confidence если < -1.0
    #      (best-practice Whisper, см. arxiv 2509.07195v1)
    #   5. hallucination check — типичные RU Whisper-галлюцинации на silence/noise
    #      ("Продолжение следует...", "Подписывайтесь на канал" и т.п.)
    #
    # Future fallback chain (см. Phase 7 plan): Groq → OpenAI Whisper API → Yandex SpeechKit.
    # MVP — только Groq (free tier 28800 sec/day, RU поддержка хорошая).
    #
    # @example
    #   res = Telegram::WorkBot::VoiceTranscriber.call(file_id: 'AwACAg...')
    #   res.success?            # => true
    #   res.text                # => "Васе позвонить клиенту [PHONE] до 16:00"
    #   res.confidence          # => -0.28 (avg log prob; > -1.0 = high confidence)
    #   res.low_confidence?     # => false
    #   res.hallucination?      # => false
    #   res.duration_sec        # => 4
    #   res.model               # => "whisper-large-v3-turbo"
    #
    # ⚠️  PII safety (Phase 7.7):
    #   • res.text — уже redacted через Privacy::TranscriptRedactor (телефоны/паспорта/ИНН/email → токены)
    #   • res.raw['text'] — ОРИГИНАЛЬНЫЙ текст с PII. НЕ персистить в БД без TTL/encrypted!
    #     Допустимо передавать в LLM tool-call (TaskExtractor) — это ephemeral.
    class VoiceTranscriber
      class Error < StandardError; end
      class MissingKeyError < Error; end
      class DownloadError < Error; end
      class GroqError < Error; end

      DEFAULT_MODEL  = 'whisper-large-v3-turbo'
      FALLBACK_MODEL = 'whisper-large-v3'
      LOW_CONFIDENCE_THRESHOLD = -1.0
      MAX_DURATION_SEC = 300 # 5 минут — больше отказываемся транскрибировать (см. plan edge case)

      # Russian-Whisper типичные галлюцинации на silence/noise.
      # Источник: empirical наблюдения + Whisper RU community reports.
      # При full-match (после strip + downcase) — флаг hallucination=true, text=''.
      HALLUCINATION_BLACKLIST = [
        /\Aпродолжение следует\.?\.?\.?\z/i,
        /\Aспасибо за просмотр\.?\z/i,
        /\Aподписывайтесь на канал\.?\z/i,
        /\Aсубтитры сделал/i,
        /\Aкорректор\b/i,
        /\Aредактор субтитров/i,
        /\A♪/
      ].freeze

      Result = Struct.new(:text, :confidence, :duration_sec, :model, :raw,
                          :low_confidence, :hallucination, :error, keyword_init: true) do
        def success? = error.nil?
        def low_confidence? = !!low_confidence
        def hallucination? = !!hallucination
      end

      def self.call(file_id:, **)
        new(file_id: file_id, **).call
      end

      def initialize(file_id:, tg_client: Telegram::Client.new, model: DEFAULT_MODEL, http: nil)
        @file_id   = file_id
        @tg_client = tg_client
        @model     = model
        @http      = http # для тестов — можно injection'ить
      end

      def call
        ensure_api_key!

        tmp = @tg_client.download_file(@file_id, prefix: 'voice-')
        raise DownloadError, "TG download failed for file_id=#{@file_id}" unless tmp

        begin
          raw = transcribe(tmp.path)
          build_result(raw)
        ensure
          tmp.close
          tmp.unlink
        end
      rescue Error => e
        Result.new(text: '', confidence: nil, duration_sec: nil, model: @model,
                   raw: nil, low_confidence: false, hallucination: false, error: e.message)
      end

      private

      def ensure_api_key!
        return if ENV['GROQ_API_KEY'].present?

        raise MissingKeyError, 'GROQ_API_KEY not set in ENV (Phase 7.1)'
      end

      def transcribe(local_path)
        boundary = "----victory-stt-#{SecureRandom.hex(8)}"
        body = build_multipart(local_path, boundary)

        uri = URI('https://api.groq.com/openai/v1/audio/transcriptions')
        req = Net::HTTP::Post.new(uri,
                                  'Content-Type' => "multipart/form-data; boundary=#{boundary}",
                                  'Authorization' => "Bearer #{ENV.fetch('GROQ_API_KEY')}")
        req.body = body

        res = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                                                  open_timeout: 5, read_timeout: 60) { |h| h.request(req) }
        data = parse_json(res.body)
        raise GroqError, "Groq STT failed: HTTP #{res.code} #{data['error']&.dig('message')}" unless res.is_a?(Net::HTTPSuccess)

        data
      end

      def build_multipart(local_path, boundary)
        filename = File.basename(local_path)
        content  = File.binread(local_path)

        parts = String.new(encoding: 'ASCII-8BIT')
        parts << form_field(boundary, 'model', @model)
        parts << form_field(boundary, 'language', 'ru')
        parts << form_field(boundary, 'response_format', 'verbose_json')
        parts << form_field(boundary, 'temperature', '0')
        parts << form_file(boundary, 'file', filename, 'audio/ogg', content)
        parts << "--#{boundary}--\r\n".b
        parts
      end

      def form_field(boundary, name, value)
        "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{name}\"\r\n\r\n#{value}\r\n".b
      end

      def form_file(boundary, name, filename, content_type, content)
        head = "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{name}\"; filename=\"#{filename}\"\r\n" \
               "Content-Type: #{content_type}\r\n\r\n".b
        head + content.dup.force_encoding('ASCII-8BIT') + "\r\n".b
      end

      def parse_json(body)
        JSON.parse(body.to_s)
      rescue JSON::ParserError
        {}
      end

      def build_result(raw)
        raw_text   = raw['text'].to_s.strip
        duration   = raw['duration'].to_i
        confidence = aggregate_confidence(raw['segments'])

        if duration > MAX_DURATION_SEC
          return Result.new(text: '', confidence: confidence, duration_sec: duration,
                            model: @model, raw: raw, low_confidence: false, hallucination: false,
                            error: "voice too long (#{duration}s > #{MAX_DURATION_SEC}s)")
        end

        hallucination = hallucination?(raw_text)
        low           = confidence.present? && confidence < LOW_CONFIDENCE_THRESHOLD

        # Phase 7.7 — PII redaction ПЕРЕД return. Hallucination check на raw_text
        # (т.к. blacklist match'ит цельные фразы, не маскированный текст).
        # Если hallucination=true → text=''; иначе → redacted text.
        # raw остаётся в результате для downstream (TaskExtractor) — но caller
        # ОБЯЗАН не персистить raw['text'] в БД без TTL/encryption (см. Phase 7.2).
        output_text = if hallucination
                        ''
                      else
                        Privacy::TranscriptRedactor.call(raw_text)
                      end

        Result.new(text: output_text,
                   confidence: confidence,
                   duration_sec: duration,
                   model: @model,
                   raw: raw,
                   low_confidence: low,
                   hallucination: hallucination,
                   error: nil)
      end

      # avg_logprob per-segment → среднее по всем сегментам.
      # Если segments нет (короткое сообщение без segmentation) — nil.
      def aggregate_confidence(segments)
        return nil if segments.blank?

        values = Array(segments).pluck('avg_logprob').compact
        return nil if values.empty?

        (values.sum / values.size.to_f).round(3)
      end

      def hallucination?(text)
        return false if text.blank?

        normalized = text.strip
        HALLUCINATION_BLACKLIST.any? { |re| normalized.match?(re) }
      end
    end
  end
end
