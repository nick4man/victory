# frozen_string_literal: true

# A6 Phase 1 foundation: client document intake table для
# passport/ИНН/выписка ЕГРН uploaded via Telegram bot.
#
# Disambiguation: separate from existing `documents` table (which holds
# property-side legal documents — договоры, сертификаты, тех.паспорта,
# свидетельства). `client_documents` — это client-uploaded identity/KYC
# documents с OCR processing flow.
#
# Sensitive fields (passport_number, birth_date, full_name) хранятся
# в parsed_data jsonb. DLP через filter_parameter_logging — passport
# номер никогда не попадает в plain logs.
class CreateClientDocuments < ActiveRecord::Migration[7.1]
  def change
    create_table :client_documents do |t|
      t.references :uploader, null: false, foreign_key: { to_table: :users }
      t.references :inquiry, foreign_key: true # optional — для linking к deal pipeline

      t.integer :document_kind, null: false, default: 0 # enum: passport/inn/egrn/...
      t.integer :status,        null: false, default: 0 # enum: received/ocr_processing/...

      t.string   :tg_chat_id
      t.string   :tg_message_id
      t.string   :tg_file_id    # Telegram CDN reference (re-download anytime)

      t.jsonb    :yandex_vision_response, default: {}
      t.jsonb    :parsed_data,            default: {}

      t.text     :ocr_raw_text   # для debug / re-parse
      t.text     :error_message  # если parser fail

      t.datetime :processed_at
      t.datetime :reviewed_at    # admin/agent confirmed correctness
      t.bigint   :reviewed_by_user_id

      t.timestamps
    end

    add_index :client_documents, :document_kind
    add_index :client_documents, :status
    add_index :client_documents, %i[tg_chat_id tg_message_id]
    add_index :client_documents, :processed_at
  end
end
