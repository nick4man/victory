# frozen_string_literal: true

module Nextcloud
  # Phase 7.8b — Архивация voice-сообщений Оксаны в Nextcloud для audit-trail.
  #
  # Upload pair: оригинальный .ogg + redacted transcript .txt в:
  #   Офис/НЕДВИЖИМОСТЬ/AUDIT-LOGS/voice-tasks/YYYY-MM/YYYYMMDD-HHmmss-<actor>.{ogg,txt}
  #
  # Sensitivity-tier: Domain-work (под НЕДВИЖИМОСТЬ). Если voice содержит
  # client PII даже после Privacy::TranscriptRedactor — это backup защита,
  # т.к. путь доступен только staff с NC credentials.
  #
  # Soft-fail: любая ошибка (NC down, mkdir failed, upload denied) → log warn
  # + return nil. НЕ блокирует VoiceIntakeProcessor pipeline.
  #
  # Создаёт DocumentUpload record для KPI documents_uploaded tracking.
  #
  # @example
  #   res = Nextcloud::VoiceArchiver.call(
  #     file_id:    'AwACAg...',
  #     transcript: 'Васе позвонить [PHONE] до 16:00',
  #     actor:      oksana_tg_user,
  #     task_batch_id: 42
  #   )
  #   res.success?         # => true
  #   res.audio_path       # => 'Офис/НЕДВИЖИМОСТЬ/AUDIT-LOGS/voice-tasks/2026-05/20260517-130000-oks07victory.ogg'
  #   res.document_upload  # => DocumentUpload record
  class VoiceArchiver
    ROOT = 'Офис/НЕДВИЖИМОСТЬ/AUDIT-LOGS/voice-tasks'

    Result = Struct.new(:audio_path, :transcript_path, :document_upload, :error,
                        keyword_init: true) do
      def success? = error.nil?
    end

    def self.call(...)
      new(...).call
    end

    def initialize(file_id:, transcript:, actor:, task_batch_id: nil,
                   tg_client: Telegram::Client.new, nc_client: Nextcloud::Client.new)
      @file_id        = file_id
      @transcript     = transcript.to_s
      @actor          = actor
      @task_batch_id  = task_batch_id
      @tg_client      = tg_client
      @nc_client      = nc_client
    end

    def call
      ensure_dir!
      audio_path, transcript_path = upload_pair
      record = persist_upload(audio_path, transcript_path)
      Result.new(audio_path: audio_path, transcript_path: transcript_path,
                 document_upload: record, error: nil)
    rescue StandardError => e
      Rails.logger.warn("[Nextcloud::VoiceArchiver] #{e.class}: #{e.message}")
      Result.new(audio_path: nil, transcript_path: nil, document_upload: nil, error: e.message)
    end

    private

    def ensure_dir!
      # Каждый месяц новая subdir под `voice-tasks/YYYY-MM/`. mkdir_p
      # рекурсивно создаст AUDIT-LOGS/ если ещё нет (новая ветка taxonomy).
      @nc_client.mkdir_p(month_dir)
    end

    def month_dir
      "#{ROOT}/#{Time.current.strftime('%Y-%m')}"
    end

    def filename_stem
      ts    = Time.current.strftime('%Y%m%d-%H%M%S')
      actor = @actor.tg_username.presence || "tg#{@actor.tg_user_id}"
      "#{ts}-#{actor}"
    end

    def upload_pair
      tmp = @tg_client.download_file(@file_id, prefix: 'voice-archive-')
      raise 'TG download failed' if tmp.nil?

      audio_path      = "#{month_dir}/#{filename_stem}#{File.extname(tmp.path)}"
      transcript_path = "#{month_dir}/#{filename_stem}.txt"

      begin
        @nc_client.upload(tmp.path, audio_path)
        File.write(transcript_tmp_path, @transcript)
        @nc_client.upload(transcript_tmp_path, transcript_path)
      ensure
        tmp.close
        tmp.unlink
        FileUtils.rm_f(transcript_tmp_path)
      end

      [audio_path, transcript_path]
    end

    def transcript_tmp_path
      @transcript_tmp_path ||= "/tmp/voice-transcript-#{SecureRandom.hex(6)}.txt"
    end

    def persist_upload(audio_path, _transcript_path)
      DocumentUpload.create!(
        uploaded_by: @actor,
        nextcloud_path: audio_path,
        file_name: File.basename(audio_path),
        file_size: 0, # NC не возвращает size легко; точное значение Phase 7.8b+
        content_type: 'audio/ogg',
        purpose: 'voice-archive',
        uploaded_at: Time.current,
        related_task_id: nil
      )
    rescue StandardError => e
      Rails.logger.warn("[Nextcloud::VoiceArchiver] DocumentUpload persist failed: #{e.message}")
      # Файлы в NC уже загружены — не rollback'аем. Без DocumentUpload только
      # KPI документов будет недосчёт на этот случай.
      nil
    end
  end
end
