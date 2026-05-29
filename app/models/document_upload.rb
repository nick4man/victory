# frozen_string_literal: true

# Phase 7.8a — лог загрузок документов в Nextcloud ботом.
# Используется как источник KPI metric `documents_uploaded_count` для
# StaffMetric (Phase 7.6).
#
# @example
#   DocumentUpload.create!(
#     uploaded_by: tg_user,
#     nextcloud_path: 'Офис/.../audio.ogg',
#     file_name: 'audio.ogg', file_size: 12_345,
#     purpose: 'voice-archive',
#     uploaded_at: Time.current
#   )
class DocumentUpload < ApplicationRecord
  belongs_to :uploaded_by, class_name: 'TelegramUser'

  validates :nextcloud_path, presence: true
  validates :file_name,      presence: true
  validates :uploaded_at,    presence: true

  scope :not_deleted, -> { where(deleted_at: nil) }
  scope :for_staff,   ->(tg_user) { where(uploaded_by: tg_user) }
  scope :on_date,     ->(date) { where(uploaded_at: date.all_day) }

  default_scope { not_deleted }

  def soft_delete!
    update!(deleted_at: Time.current)
  end
end
