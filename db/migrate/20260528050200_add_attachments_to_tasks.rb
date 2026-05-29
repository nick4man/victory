# frozen_string_literal: true

# Iter 60 — поддержка фото/документов на Task. Когда директор шлёт фото в DM
# и выбирает «📤 Сотрудникам с задачей» → создаётся Task с attached фото.
# Хранится list of refs: tg_file_id (для re-send в DM через sendPhoto без
# re-upload) + nc_url (public Nextcloud share link, постоянная ссылка).
#
# Schema:
#   [{ "tg_file_id":"AgAC...", "nc_url":"https://cloud.victory62.org/s/...",
#      "kind":"image|document", "uploaded_at":"2026-05-22T18:00:00Z",
#      "uploaded_by":<telegram_user_id> }]
#
# 1-5 attachments на task — JSONB достаточно. Если позже понадобится shared
# library / search by file content → миграция на polymorphic DocumentUpload.
class AddAttachmentsToTasks < ActiveRecord::Migration[7.1]
  def change
    add_column :tasks, :attachments, :jsonb, default: [], null: false
    add_index  :tasks, :attachments, using: :gin
  end
end
