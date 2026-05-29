# frozen_string_literal: true

require 'net/http'
require 'json'
require 'digest'
require 'base64'

module YandexVision
  # Net::HTTP wrapper for Yandex Cloud Vision API v1.
  #
  # Reads YANDEX_VISION_API_KEY + YANDEX_VISION_FOLDER_ID from ENV.
  # Endpoint: POST https://vision.api.cloud.yandex.net/vision/v1/batchAnalyze
  # Auth:     Authorization: Api-Key {YANDEX_VISION_API_KEY}
  #
  # Two public methods:
  #   text_detection(image, language_codes:) → raw OCR text + blocks array
  #   classify(image)                        → label confidence scores
  #
  # Caching: 24h in Rails.cache keyed by SHA1(image bytes).
  # Network errors → soft-fail (logs warn, returns nil) to keep TG flow alive.
  #
  # DLP: this class NEVER logs raw OCR text — callers must not log return values
  # directly. filter_parameter_logging covers :ocr_raw_text + :yandex_vision_response.
  class Client
    class Error < StandardError; end

    ENDPOINT     = 'https://vision.api.cloud.yandex.net'
    PATH         = '/vision/v1/batchAnalyze'
    OPEN_TIMEOUT = 15
    READ_TIMEOUT = 60
    MAX_ATTEMPTS = 3
    CACHE_TTL    = 24.hours

    def initialize(
      api_key:   ENV.fetch('YANDEX_VISION_API_KEY', nil),
      folder_id: ENV.fetch('YANDEX_VISION_FOLDER_ID', nil)
    )
      @api_key   = api_key
      @folder_id = folder_id
    end

    # Распознаёт текст на изображении.
    #
    # @param image [String] binary bytes OR URL string (https://...)
    # @param language_codes [Array<String>] e.g. ['ru', 'en']
    # @return [Hash, nil]
    #   {
    #     'text'   => String (всё распознанное, по строкам),
    #     'blocks' => Array (raw textAnnotation.pages[0].blocks from API)
    #   }
    #   nil если недоступно / ошибка сети
    def text_detection(image, language_codes: %w[ru en])
      cache_key = "yv:text:#{cache_digest(image)}"
      cached    = Rails.cache.read(cache_key)
      return cached if cached.present?

      result = with_retry do
        request_api(build_text_payload(image, language_codes))
      end
      return nil if result.nil?

      parsed = parse_text_response(result)
      Rails.cache.write(cache_key, parsed, expires_in: CACHE_TTL)
      parsed
    rescue Error => e
      Rails.logger.warn("[YandexVision::Client#text_detection] #{e.class}: #{e.message}")
      nil
    end

    # Классифицирует фото — возвращает label confidence scores.
    #
    # @param image [String] binary bytes OR URL string
    # @return [Hash, nil] e.g. { 'document' => 0.94, 'face' => 0.71 }
    #   nil если недоступно / ошибка сети
    def classify(image)
      cache_key = "yv:classify:#{cache_digest(image)}"
      cached    = Rails.cache.read(cache_key)
      return cached if cached.present?

      result = with_retry do
        request_api(build_classify_payload(image))
      end
      return nil if result.nil?

      parsed = parse_classify_response(result)
      Rails.cache.write(cache_key, parsed, expires_in: CACHE_TTL)
      parsed
    rescue Error => e
      Rails.logger.warn("[YandexVision::Client#classify] #{e.class}: #{e.message}")
      nil
    end

    private

    def request_api(payload)
      raise Error, 'YANDEX_VISION_API_KEY not set' if @api_key.blank?

      uri = URI("#{ENDPOINT}#{PATH}")
      req = Net::HTTP::Post.new(uri)
      req['Content-Type']  = 'application/json'
      req['Authorization'] = "Api-Key #{@api_key}"
      req.body = JSON.generate(payload)

      res = Net::HTTP.start(uri.host, uri.port,
                            use_ssl:      true,
                            open_timeout: OPEN_TIMEOUT,
                            read_timeout: READ_TIMEOUT) { |h| h.request(req) }

      unless res.is_a?(Net::HTTPSuccess)
        raise Error, "HTTP #{res.code}: #{res.body.to_s.truncate(300)}"
      end

      JSON.parse(res.body)
    end

    def with_retry
      attempt = 0
      begin
        attempt += 1
        yield
      rescue Error, Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, SocketError => e
        raise Error, "#{e.class}: #{e.message}" if attempt >= MAX_ATTEMPTS

        Rails.logger.warn("[YandexVision] attempt #{attempt} failed: #{e.class} — retry в #{2**attempt}s")
        sleep(2**attempt)
        retry
      end
    end

    # Изображение может быть URL или бинарными байтами.
    # Yandex Vision принимает: { url: ... } или { content: base64 }
    def image_spec(image)
      if image.to_s.start_with?('http://', 'https://')
        { url: image.to_s }
      else
        { content: Base64.strict_encode64(image.to_s) }
      end
    end

    def build_text_payload(image, language_codes)
      {
        folderId: @folder_id,
        analyze_specs: [
          {
            image: image_spec(image),
            features: [
              {
                type: 'TEXT_DETECTION',
                text_detection_config: {
                  language_codes: language_codes
                }
              }
            ]
          }
        ]
      }
    end

    def build_classify_payload(image)
      {
        folderId: @folder_id,
        analyze_specs: [
          {
            image: image_spec(image),
            features: [
              { type: 'CLASSIFICATION' }
            ]
          }
        ]
      }
    end

    def parse_text_response(raw)
      annotation = raw.dig('results', 0, 'results', 0, 'textAnnotation') || {}
      pages      = annotation['pages'] || []
      blocks     = pages.flat_map { |p| p['blocks'] || [] }

      lines = blocks.flat_map do |block|
        (block['lines'] || []).map do |line|
          (line['words'] || []).map { |w| w['text'].to_s }.join(' ')
        end
      end

      {
        'text'   => lines.join("\n"),
        'blocks' => blocks
      }
    end

    def parse_classify_response(raw)
      properties = raw.dig('results', 0, 'results', 0, 'classificationResult', 'properties') || []
      properties.each_with_object({}) do |prop, hash|
        hash[prop['name'].to_s.downcase] = prop['probability'].to_f
      end
    end

    # Стабильный ключ кэша: для URL — digest от строки; для бинарных данных — SHA1 первых 4KB.
    # Читаем только первые 4KB чтобы не держать мегабайты в памяти при хэшировании.
    def cache_digest(image)
      sample = image.to_s.byteslice(0, 4096) || ''
      Digest::SHA1.hexdigest(sample)
    end
  end
end
