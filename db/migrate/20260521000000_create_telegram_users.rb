# frozen_string_literal: true

# Сотрудники АН в Telegram-боте.
# Связка между Telegram user_id (приходит в webhook) и Topnlab user_id (нужен
# для /call/main/transferClient/ — назначение лида по email агента).
# Создаётся через команду /whoami email@victory.ru с подтверждением 6-значным
# кодом, отправленным на email; код хранится в Rails.cache (TTL 15 мин).
class CreateTelegramUsers < ActiveRecord::Migration[7.1]
  def change
    create_table :telegram_users do |t|
      t.bigint  :tg_user_id,        null: false   # уникальный id пользователя в Telegram
      t.string  :tg_username                       # @username (может меняться, не уникален как ключ)
      t.bigint  :topnlab_user_id                   # id из Topnlab /getUsers — связь с CRM
      t.string  :email                             # email сотрудника в Topnlab
      t.string  :first_name
      t.string  :last_name
      t.boolean :is_manager,        null: false, default: false  # может /assign, /close проиграно
      t.bigint  :dm_chat_id                        # chat_id личной переписки с ботом — для DM-нотификаций
      t.string  :status,            null: false, default: 'active'  # active | inactive | blocked
      t.datetime :last_seen_at

      t.timestamps
    end

    add_index :telegram_users, :tg_user_id,      unique: true
    add_index :telegram_users, :topnlab_user_id, unique: true, where: 'topnlab_user_id IS NOT NULL'
    add_index :telegram_users, :email,           where: 'email IS NOT NULL'
    add_index :telegram_users, :is_manager
  end
end
