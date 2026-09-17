# frozen_string_literal: true

# Нумерация update_id у каждого Telegram-бота своя. С тестовым ботом одно и
# то же число придёт от двух ботов, и общий уникальный индекс отбросил бы
# апдейт второго как «повтор» — молча. Дедупликация — в пределах бота.
class AddBotToTelegramWebhookAcks < ActiveRecord::Migration[8.1]
  def change
    add_column :telegram_webhook_acks, :bot, :string, null: false, default: 'main'
    remove_index :telegram_webhook_acks, :update_id, unique: true
    add_index :telegram_webhook_acks, %i[bot update_id], unique: true
  end
end
