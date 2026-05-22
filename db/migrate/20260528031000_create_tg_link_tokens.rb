# frozen_string_literal: true

# State-tokens для deep-link Telegram linking flow:
#   1. /cabinet/profile → click «Подключить TG» → POST /cabinet/tg/link
#      → TgLinkToken.generate!(user) → redirect на t.me/<bot>?start=<token>
#   2. Bot ловит /start <token> → TgLinkToken.consume!(token, tg_user_id, username)
#      → User.update!(tg_user_id:, tg_username:, tg_linked_at:)
#   3. Reply клиенту «Готово! Уведомления будут приходить сюда.»
#
# Security mirrors MagicLinkToken:
#   - 30-min TTL (UX-friendly enough — typical flow Подключить→Open bot < 1min)
#   - single-use (consumed_at NOT NULL после claim)
#   - SecureRandom.urlsafe_base64(32) — 43-char высокая энтропия
#   - audit fields: ip + UA from generate request
class CreateTgLinkTokens < ActiveRecord::Migration[7.1]
  def change
    create_table :tg_link_tokens do |t|
      t.references :user, null: false, foreign_key: true
      t.string   :token, null: false, limit: 64
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.string   :ip_address, limit: 45
      t.string   :user_agent, limit: 255
      t.timestamps
    end

    add_index :tg_link_tokens, :token, unique: true
    add_index :tg_link_tokens, :expires_at
  end
end
