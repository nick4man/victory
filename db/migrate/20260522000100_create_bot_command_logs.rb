# frozen_string_literal: true

# Аудит команд TG-бота — минимальный лог для отладки и метрик adoption.
# Не имеет UI; читается через `BotCommandLog.where(...).order(created_at: :desc)` в консоли.
# Phase 3 добавит rate-limit (max 30 cmd/min) с использованием этого же лога.
class CreateBotCommandLogs < ActiveRecord::Migration[7.1]
  def change
    create_table :bot_command_logs do |t|
      t.bigint   :tg_user_id, null: false              # id юзера в Telegram (не FK — пишем даже для незарегистрированных)
      t.string   :command,    null: false              # '/lead' | '/route' | '/assign' | ...
      t.text     :args
      t.string   :result                               # 'ok' | 'error' | 'forbidden' | 'unknown_command'
      t.string   :error_class                          # имя класса исключения при result='error'
      t.datetime :created_at, null: false
    end

    add_index :bot_command_logs, %i[tg_user_id created_at]
    add_index :bot_command_logs, :command
    add_index :bot_command_logs, :result
  end
end
