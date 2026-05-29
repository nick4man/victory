# frozen_string_literal: true

module Nextcloud
  # Phase 7.8a — кеш Nextcloud share links для idempotency.
  #
  # При повторном `ShareLinkGenerator.for(path)` находит existing запись по
  # `path_sha256`, проверяет `expires_at` и возвращает (или создаёт fresh).
  # Это убирает дублирование OCS API calls + сохраняет password между
  # обращениями (Nextcloud не возвращает password в GET-shares).
  #
  # @note Password стороной хранится в plain. Risk profile тот же что у URL —
  #   оба элемента нужны вместе. Phase 7.6+ переход на `encrypts :password`.
  class ShareLink < ApplicationRecord
    self.table_name = 'nextcloud_share_links'

    belongs_to :created_by, class_name: 'TelegramUser', optional: true

    validates :path,        presence: true
    validates :path_sha256, presence: true, uniqueness: { conditions: -> { where(deleted_at: nil) } }
    validates :share_url,   presence: true

    scope :not_deleted, -> { where(deleted_at: nil) }
    scope :active,      -> { not_deleted.where('expires_at IS NULL OR expires_at >= ?', Time.current) }

    default_scope { not_deleted }

    def expired?
      expires_at.present? && expires_at < Time.current
    end

    # Soft-delete: НЕ удаляет share в Nextcloud (это требует OCS API call —
    # делается отдельно). Только убирает из активного кеша.
    def soft_delete!
      update!(deleted_at: Time.current)
    end

    # Стабильный idempotency key для пути.
    def self.fingerprint(path)
      Digest::SHA256.hexdigest(path.to_s)
    end
  end
end
