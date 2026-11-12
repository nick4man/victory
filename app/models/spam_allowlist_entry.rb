# frozen_string_literal: true

# Популярные белые домены (снапшот Cisco Umbrella Top-10k, синкается
# Llm::SpamFeeds::SyncJob). Локальные эвристики не имеют права автоблочить
# корень такого домена — только конкретный путь (t.me/spam_channel).
class SpamAllowlistEntry < ApplicationRecord
  default_scope { not_deleted }
  scope :not_deleted, -> { where(deleted_at: nil) }

  validates :domain, presence: true

  def self.allowlisted?(domain)
    domain.present? && exists?(domain: domain.to_s.downcase)
  end
end
