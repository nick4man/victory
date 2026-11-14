# frozen_string_literal: true

class CreateAvitoWebhookAcks < ActiveRecord::Migration[7.1]
  def change
    create_table :avito_webhook_acks do |t|
      t.string :message_id, null: false
      t.datetime :processed_at, null: false
      t.datetime :deleted_at

      t.timestamps
    end

    add_index :avito_webhook_acks, :message_id, unique: true, where: 'deleted_at IS NULL'
  end
end
