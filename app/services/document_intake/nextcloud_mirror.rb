# frozen_string_literal: true

module DocumentIntake
  # A6 Phase 2 — Зеркалирует parsed_data ClientDocument в Nextcloud для compliance:
  #   <Type>/<deal-folder>/client-intake/<kind>-YYYYMMDD.json
  #
  # Зачем:
  #   • Audit-trail вне приложения (independent of DB backup)
  #   • Sensitive-tier isolation: subdir client-intake/ — DLP boundary внутри
  #     deal-folder (cheatsheet: «OCR client docs (sensitive)»)
  #   • Other agents (case-study-writer, contract-drafter) могут читать parsed
  #     data из NC напрямую без DB-доступа
  #
  # Soft-fail: любая ошибка NC → log warn + nil return. НЕ блокирует ParserJob.
  #
  # JSON payload включает masked parsed_data (DLP-safe) — full data остаётся
  # только в БД с filter_parameter_logging + (Phase 7+) AR encryption.
  #
  # @example
  #   res = DocumentIntake::NextcloudMirror.call(client_document: doc)
  #   res.nextcloud_path # => "Офис/НЕДВИЖИМОСТЬ/КВАРТИРЫ/РЯЗАНЬ/<deal>/client-intake/passport-20260518.json"
  #   res.document_upload # => DocumentUpload record
  class NextcloudMirror
    Result = Struct.new(:nextcloud_path, :document_upload, :error,
                        keyword_init: true) do
      def success? = error.nil?
    end

    def self.call(...)
      new(...).call
    end

    def initialize(client_document:, nc_client: Nextcloud::Client.new)
      @doc       = client_document
      @nc_client = nc_client
    end

    def call
      return empty('no parsed_data') if @doc.parsed_data.blank?

      deal_dir = resolve_deal_dir
      return empty('no property/inquiry to resolve deal-folder') unless deal_dir

      intake_dir = "#{deal_dir}/client-intake"
      @nc_client.mkdir_p(intake_dir)

      json_path = "#{intake_dir}/#{filename}"
      payload   = build_payload
      upload_json!(json_path, payload)

      @doc.update_columns(nextcloud_path: json_path)
      record = persist_upload(json_path, payload.bytesize)

      Result.new(nextcloud_path: json_path, document_upload: record, error: nil)
    rescue Nextcloud::Client::Forbidden => e
      Rails.logger.warn("[DocumentIntake::NextcloudMirror] sensitive path blocked: #{e.message}")
      Result.new(nextcloud_path: nil, document_upload: nil, error: 'sensitive_path')
    rescue StandardError => e
      Rails.logger.warn("[DocumentIntake::NextcloudMirror] #{e.class}: #{e.message}")
      Result.new(nextcloud_path: nil, document_upload: nil, error: e.message)
    end

    private

    def empty(reason)
      Rails.logger.info("[DocumentIntake::NextcloudMirror] skip ##{@doc.id}: #{reason}")
      Result.new(nextcloud_path: nil, document_upload: nil, error: reason)
    end

    def resolve_deal_dir
      property = @doc.property || @doc.inquiry&.property
      return nil if property.nil?

      Nextcloud::DealFolderResolver.for(property: property, inquiry: @doc.inquiry).path
    end

    def filename
      "#{@doc.document_kind}-#{Time.current.strftime('%Y%m%d-%H%M%S')}.json"
    end

    def build_payload
      JSON.pretty_generate(
        client_document_id: @doc.id,
        document_kind: @doc.document_kind,
        status: @doc.status,
        uploader_id: @doc.uploader_id,
        parsed_data_masked: @doc.parsed_data_masked, # NC хранит ТОЛЬКО masked
        processed_at: @doc.processed_at&.iso8601,
        tg_chat_id: @doc.tg_chat_id,
        mirrored_at: Time.current.iso8601
      )
    end

    def upload_json!(path, payload)
      tmp = "/tmp/cd-#{@doc.id}-#{SecureRandom.hex(6)}.json"
      File.write(tmp, payload)
      @nc_client.upload(tmp, path)
    ensure
      FileUtils.rm_f(tmp) if tmp
    end

    # DocumentUpload требует staff TelegramUser (для KPI documents_uploaded
    # счётчика). Client-intake — это client photo, не staff action, поэтому
    # DocumentUpload создаётся ТОЛЬКО при ручной admin-загрузке (есть
    # reviewed_by_user_id с TelegramUser маппингом). На MVP — skip.
    def persist_upload(path, size)
      return nil if @doc.reviewed_by_user_id.blank?

      tg_user = TelegramUser.find_by(email: @doc.reviewed_by&.email)
      return nil if tg_user.nil?

      DocumentUpload.create!(
        uploaded_by: tg_user,
        nextcloud_path: path,
        file_name: File.basename(path),
        file_size: size,
        content_type: 'application/json',
        purpose: 'client-intake',
        related_property_id: @doc.property_id || @doc.inquiry&.property_id,
        uploaded_at: Time.current
      )
    rescue StandardError => e
      Rails.logger.warn("[DocumentIntake::NextcloudMirror] DocumentUpload persist: #{e.message}")
      nil
    end
  end
end
