# frozen_string_literal: true

# Phase 7.8a — кеш Nextcloud share links для idempotency.
# При повторном create_share на тот же path — возвращаем existing запись
# (если не expired); иначе создаём новую через OCS API.
#
# Password хранится в plain text — same risk profile как сам share URL
# (оба нужны вместе для доступа). Phase 7.6+ — переход на `encrypts :password`
# когда настроим ActiveRecord::Encryption ключи.
class CreateNextcloudShareLinks < ActiveRecord::Migration[7.1]
  def change
    create_table :nextcloud_share_links do |t|
      t.string   :path_sha256,  null: false, limit: 64 # SHA-256 от full path (idempotency key)
      t.text     :path,         null: false # human-readable path для аудита
      t.string   :share_url,    null: false
      t.string   :share_token # из OCS response
      t.string   :password                                # plain для MVP, см. комментарий выше
      t.integer  :nc_share_id                             # OCS Share resource id
      t.datetime :expires_at
      t.bigint   :created_by_id                           # FK логический → telegram_users
      t.datetime :deleted_at, index: true # soft-delete
      t.timestamps
    end

    add_index :nextcloud_share_links, :path_sha256, unique: true,
                                                    where: 'deleted_at IS NULL',
                                                    name: 'idx_nc_share_links_active_path'
    add_index :nextcloud_share_links, :expires_at
    add_index :nextcloud_share_links, :created_by_id
  end
end
