# frozen_string_literal: true

# Polymorphic comments mirroring Topnlab public notes (`/get-notes`/`/set-note`).
# Pull = `Topnlab::NotesSyncService#pull` populates rows from CRM with crm_note_id.
# Push = agent writes locally → TopnlabNotePushJob calls `set-note` → fills crm_note_id.
class Note < ApplicationRecord
  belongs_to :notable, polymorphic: true
  belongs_to :user, optional: true

  SYNC_STATES = %w[pending synced failed].freeze

  scope :synced,  -> { where(sync_state: 'synced') }
  scope :pending, -> { where(sync_state: 'pending') }
  scope :failed,  -> { where(sync_state: 'failed') }
  scope :recent,  -> { order(created_at: :desc) }

  validates :note, presence: true, length: { maximum: 5000 }
  validates :sync_state, inclusion: { in: SYNC_STATES }

  def author_name
    user&.short_name.presence ||
      User.find_by(crm_user_id: crm_user_id)&.short_name ||
      'Сотрудник CRM'
  end

  def synced?; sync_state == 'synced'; end
  def pending?; sync_state == 'pending'; end
  def failed?; sync_state == 'failed'; end
end
