# frozen_string_literal: true

# Phase A — TG-first cabinet invitation infra. Clients могут подключить
# свой Telegram аккаунт к user record для free push-notifications
# (cabinet invites, deal events, document requests).
#
# Columns:
#   tg_user_id  — bigint, telegram user.id (same as chat_id для private DMs).
#                 unique index — один TG аккаунт = один User. Null = не подключён.
#   tg_username — display-only (@handle). Mutable на TG side, не используется для auth.
#   tg_linked_at — audit timestamp, когда состоялся linkage через ClientBot::LinkProcessor.
class AddTgUserIdToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :tg_user_id,   :bigint
    add_column :users, :tg_username,  :string,   limit: 64
    add_column :users, :tg_linked_at, :datetime

    add_index :users, :tg_user_id, unique: true, where: 'tg_user_id IS NOT NULL'
  end
end
