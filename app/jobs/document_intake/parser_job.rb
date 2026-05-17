# frozen_string_literal: true

module DocumentIntake
  # Async OCR job. Invoked by Telegram::InboundProcessor after ClientDocument.intake!
  #
  # Flow:
  #   1. Mark doc ocr_processing
  #   2. Download photo binary from Telegram CDN (via tg_file_id)
  #   3. Run YandexVision text_detection
  #   4. Dispatch to kind-specific parser (PassportParser / InnParser / EgrnParser)
  #   5. Persist parsed_data + mark ocr_completed
  #   6. Notify staff via TELEGRAM_STAFF_CHAT_ID (DLP-safe summary)
  #
  # On any failure → ocr_failed + error_message (truncated, no raw PII).
  #
  # Retries: ApplicationJob base provides exponential backoff up to 3 attempts.
  class ParserJob < ApplicationJob
    queue_as :document_intake

    # @param document_id [Integer]
    def perform(document_id)
      doc = ClientDocument.find_by(id: document_id)
      return Rails.logger.warn("[ParserJob] ClientDocument ##{document_id} not found, skipping") unless doc

      # Idempotency guard — не запускать повторно если уже обработан
      if doc.status_ocr_completed? || doc.status_reviewed?
        Rails.logger.info("[ParserJob] doc ##{document_id} already #{doc.status}, skip")
        return
      end

      doc.update!(status: :ocr_processing)
      process(doc)
    rescue StandardError => e
      safe_msg = "[ParserJob] doc ##{document_id}: #{e.class} — #{e.message.to_s.truncate(200)}"
      Rails.logger.error(safe_msg)

      # Попытка пометить ocr_failed — может уже удалён
      ClientDocument.find_by(id: document_id)&.update(
        status:        :ocr_failed,
        error_message: "#{e.class}: #{e.message.to_s.truncate(500)}"
      )
      raise  # перебрасываем для ApplicationJob retry chain
    end

    private

    def process(doc)
      # 1. Скачать фото с Telegram CDN
      tg_client   = Telegram::Client.new
      image_bytes = fetch_image(tg_client, doc.tg_file_id)

      # 2. OCR через Yandex Vision
      yv_client   = YandexVision::Client.new
      ocr_result  = yv_client.text_detection(image_bytes)
      raw_text    = ocr_result&.dig('text').to_s
      yv_response = ocr_result || {}

      # 3. Dispatch к парсеру по document_kind
      parsed = dispatch_parser(doc.document_kind, raw_text)

      # 4. Persist
      doc.update!(
        status:                 :ocr_completed,
        parsed_data:            parsed,
        ocr_raw_text:           raw_text.truncate(10_000),
        yandex_vision_response: yv_response,
        processed_at:           Time.current
      )

      # 5. Staff notification (DLP-safe)
      notify_staff(doc)

      Rails.logger.info("[ParserJob] doc ##{doc.id} kind=#{doc.document_kind} ocr_completed confidence=#{parsed[:confidence]}")
    end

    def fetch_image(tg_client, file_id)
      tmp = tg_client.download_file(file_id, prefix: 'doc-intake')
      return nil if tmp.nil?

      tmp.read
    ensure
      tmp&.close
      tmp&.unlink
    end

    def dispatch_parser(document_kind, raw_text)
      case document_kind
      when 'passport'
        DocumentIntake::PassportParser.call(raw_text)
      when 'inn'
        DocumentIntake::InnParser.call(raw_text)
      when 'egrn'
        DocumentIntake::EgrnParser.call(raw_text)
      else
        # contract / other — нет структурированного парсера, сохраняем raw_text
        { kind: document_kind, confidence: 0.5 }
      end
    end

    def notify_staff(doc)
      chat_id = ENV['TELEGRAM_STAFF_CHAT_ID']
      return Rails.logger.warn('[ParserJob#notify_staff] TELEGRAM_STAFF_CHAT_ID not set') if chat_id.blank?

      # DLP-safe summary: mask sensitive fields before building message
      masked  = doc.parsed_data_masked
      kind_ru = kind_label(doc.document_kind)
      conf    = doc.parsed_data&.dig('confidence') || doc.parsed_data&.dig(:confidence)
      conf_pct = conf ? format('%.0f%%', conf.to_f * 100) : '—'

      # ФИО — не secret, допустимо в staff notification
      fio = extract_fio_for_notify(doc)

      text = [
        "📄 <b>Новый документ #{kind_ru}</b>",
        fio.present? ? "Клиент: #{fio}" : nil,
        "Качество распознавания: #{conf_pct}",
        "Статус: #{conf.to_f >= 0.85 ? '✅ распознан' : '⚠️ требует проверки'}",
        '',
        "Просмотр: /admin/client_documents/#{doc.id}"
      ].compact.join("\n")

      Telegram::Client.new.send_message(text, chat_id: chat_id, parse_mode: 'HTML')
    rescue StandardError => e
      Rails.logger.warn("[ParserJob#notify_staff] notification failed: #{e.class} #{e.message}")
      # Не падаем — notification failure не должна ронять успешный OCR
    end

    def extract_fio_for_notify(doc)
      pd = doc.parsed_data || {}
      parts = [pd['last_name'] || pd[:last_name],
               pd['first_name']&.chars&.first&.then { |c| "#{c}." },
               pd['middle_name']&.chars&.first&.then { |c| "#{c}." }].compact
      parts.join(' ').presence
    end

    def kind_label(kind)
      {
        'passport' => 'Паспорт РФ',
        'inn'      => 'ИНН',
        'egrn'     => 'Выписка ЕГРН',
        'contract' => 'Договор',
        'other'    => 'Документ'
      }.fetch(kind.to_s, 'Документ')
    end
  end
end
