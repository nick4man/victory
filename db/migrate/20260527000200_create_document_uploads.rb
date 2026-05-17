# frozen_string_literal: true

# Phase 7.8a — лог загрузок документов в Nextcloud ботом.
#
# Создаётся каждый раз когда бот (или сервис) загружает файл в NC.
# Является источником KPI metric `documents_uploaded_count` для StaffMetric
# (Phase 7.6). Manual uploads через NC UI НЕ tracking-аются (это ограничение
# MVP — см. plan open question #11).
class CreateDocumentUploads < ActiveRecord::Migration[7.1]
  def change
    create_table :document_uploads do |t|
      t.bigint   :uploaded_by_id,   null: false  # FK логический → telegram_users
      t.string   :nextcloud_path,   null: false
      t.string   :file_name,        null: false
      t.bigint   :file_size,        null: false, default: 0
      t.string   :content_type
      t.bigint   :related_task_id                # FK логический → tasks (optional)
      t.bigint   :related_property_id            # FK логический → properties (optional)
      t.bigint   :related_lead_event_id          # FK логический → lead_events (optional)
      t.string   :purpose                        # 'voice-archive' | 'task-document' | 'manual' | 'case-study' | ...
      t.datetime :uploaded_at,      null: false
      t.datetime :deleted_at,       index: true
      t.timestamps
    end

    add_index :document_uploads, [:uploaded_by_id, :uploaded_at]
    add_index :document_uploads, :related_task_id
    add_index :document_uploads, :related_property_id
    add_index :document_uploads, :related_lead_event_id
    add_index :document_uploads, :purpose
  end
end
