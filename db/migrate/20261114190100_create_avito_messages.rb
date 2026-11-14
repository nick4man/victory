# frozen_string_literal: true

class CreateAvitoMessages < ActiveRecord::Migration[7.1]
  def change
    create_table :avito_messages do |t|
      t.string :message_id, null: false
      t.string :chat_id, null: false
      t.bigint :author_id, null: false
      t.bigint :user_id, null: false
      t.bigint :item_id
      t.references :property, null: true, foreign_key: true

      t.string :content_type, null: false
      t.text :content_text
      t.jsonb :payload, null: false, default: {}

      t.string :direction, null: false, default: 'incoming'
      t.datetime :routed_at

      t.timestamps
    end

    add_index :avito_messages, :message_id, unique: true
    add_index :avito_messages, %i[chat_id created_at]
    add_index :avito_messages, %i[property_id created_at]
  end
end
