# frozen_string_literal: true

# Phase 14 Iter 52 — full error_message text для BotCommandLog.
# До этого фикса debugging failed commands: видим result='error' +
# error_class='Telegram::Client::Error', но текст ошибки потерян. Невозможно
# diagnose без full prod logs grep.
class AddErrorMessageToBotCommandLogs < ActiveRecord::Migration[7.1]
  def change
    add_column :bot_command_logs, :error_message, :text
  end
end
