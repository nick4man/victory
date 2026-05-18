# frozen_string_literal: true

# A6 Phase 1: client identity/KYC document intake (passport, ИНН, выписка
# ЕГРН) uploaded через Telegram bot photo.
#
# Disambiguation: separate from `Document` model (property-side legal
# attachments — договоры, тех.паспорта). `ClientDocument` — это
# client-uploaded scans with OCR pipeline.
#
# Lifecycle:
#   1. Client отправляет photo в TG personal-bot
#   2. Telegram::InboundProcessor (extended) — детектит photo + classifier
#   3. DocumentIntake::PhotoClassifier → document_kind (passport/inn/egrn)
#   4. ClientDocument.intake!(...) → status: :received
#   5. DocumentIntake::<Kind>Parser job → Yandex Vision OCR → parsed_data
#   6. ClientDocument.update!(status: :ocr_completed, parsed_data: {...})
#   7. Notification агенту в TG: «Документ распознан, проверьте поля»
#   8. Agent reviews — Document.update!(reviewed_at:, reviewed_by_user_id:)
#
# DLP rules:
#   - parsed_data ВСЕГДА masked в Rails.logger через filter_parameter_logging
#     (set'ится client-onboarding-bot агентом в Phase 2)
#   - UI render — masked values (mask_passport / mask_inn helpers)
#   - Phase 2: Rails 7 `encrypts :parsed_data, :ocr_raw_text` (нужны
#     active_record_encryption keys в credentials)
class ClientDocument < ApplicationRecord
  belongs_to :uploader, class_name: 'User'
  belongs_to :inquiry, optional: true
  belongs_to :property, optional: true # A6 Phase 2 — для NC DealFolderResolver
  belongs_to :reviewed_by, class_name: 'User', optional: true,
                           foreign_key: 'reviewed_by_user_id'

  enum :document_kind, {
    passport: 0, # Российский паспорт
    inn: 1, # ИНН
    egrn: 2, # Выписка ЕГРН
    contract: 3, # Подписанный договор (scan)
    other: 4
  }, prefix: :kind

  enum :status, {
    received: 0, # Photo получен, OCR не начался
    ocr_processing: 1, # Yandex Vision в работе
    ocr_completed: 2, # Parsed data доступен
    ocr_failed: 3, # Yandex Vision/parser упал
    reviewed: 4,  # Agent проверил correctness
    archived: 5   # Удалён client'ом / archived
  }, prefix: true

  validates :document_kind, :status, presence: true

  scope :recent,         -> { order(created_at: :desc) }
  scope :pending_review, -> { where(status: :ocr_completed, reviewed_at: nil) }
  scope :for_user,       ->(u) { where(uploader: u) }

  # DLP: возвращает masked version parsed_data для UI/logs.
  # Phase 9 Iter 2 — расширено FIO + issued_by + address masking.
  def parsed_data_masked
    return {} if parsed_data.blank?

    parsed_data.deep_dup.tap do |masked|
      masked['passport_number'] = mask_passport(masked['passport_number']) if masked['passport_number'].present?
      masked['inn']             = mask_inn(masked['inn']) if masked['inn'].present?
      masked['birth_date']      = '***.***.****' if masked['birth_date'].present?
      # ФИО — masked до first char + asterisks: "Иванов" → "И*****"
      %w[last_name first_name middle_name].each do |k|
        masked[k] = mask_name(masked[k]) if masked[k].present?
      end
      # Адрес / орган выдачи — потенциально PII (адрес проживания)
      masked['passport_issued_by'] = '[ORG]' if masked['passport_issued_by'].present?
      masked['address']            = '[ADDRESS]' if masked['address'].present?
      masked['registration_address'] = '[ADDRESS]' if masked['registration_address'].present?
    end
  end

  # Helpers — реальная masking
  def mask_passport(number)
    digits = number.to_s.gsub(/\D/, '')
    return '***' if digits.length < 10

    "#{digits[0, 2]} #{digits[2, 2]} ******"
  end

  def mask_inn(inn)
    digits = inn.to_s.gsub(/\D/, '')
    return '***' if digits.length < 5

    "#{digits[0, 2]}****#{digits[-2, 2]}"
  end

  # «Иванов» → «И*****»; «Анна» → «А***». Сохраняет первую букву для
  # частичной идентификации в admin UI без leak полного имени.
  def mask_name(name)
    s = name.to_s.strip
    return '***' if s.length < 2

    "#{s[0]}#{'*' * (s.length - 1)}"
  end

  # Factory called by Telegram::InboundProcessor (extended by agent):
  #   ClientDocument.intake!(uploader: user, kind: :passport,
  #                          tg_chat_id:, tg_message_id:, tg_file_id:)
  #
  # Phase 9 Iter 5 — Idempotent через unique index (tg_chat_id, tg_message_id).
  # При повторном photo upload (повтор client'а от плохого инета) возвращает
  # existing document вместо create duplicate. Защищает от double Groq API
  # charge + double NC mirror.
  def self.intake!(uploader:, kind:, tg_chat_id:, tg_message_id:, tg_file_id:)
    existing = find_by(tg_chat_id: tg_chat_id.to_s, tg_message_id: tg_message_id.to_s)
    return existing if existing

    create!(
      uploader: uploader,
      document_kind: kind,
      status: :received,
      tg_chat_id: tg_chat_id.to_s,
      tg_message_id: tg_message_id.to_s,
      tg_file_id: tg_file_id.to_s
    )
  rescue ActiveRecord::RecordNotUnique
    # Race: другой webhook одновременно создал ту же запись — reload и возвращаем
    find_by!(tg_chat_id: tg_chat_id.to_s, tg_message_id: tg_message_id.to_s)
  end
end
