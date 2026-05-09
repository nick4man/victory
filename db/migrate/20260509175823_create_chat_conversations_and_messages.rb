# frozen_string_literal: true

# Anonymous-aware live chat conversations + messages.
# `conversation` differs from existing `Message`/`conversation_id` (User↔User direct
# messaging); this is for the public widget where visitors may have no User account.
# `visitor_token` is a signed cookie value persisted across page loads.
class CreateChatConversationsAndMessages < ActiveRecord::Migration[7.1]
  def change
    create_table :conversations do |t|
      t.string  :visitor_token, null: false
      t.references :user,           foreign_key: true
      t.references :assigned_user,  foreign_key: { to_table: :users }
      t.string   :name
      t.string   :phone
      t.string   :email
      t.integer  :status, default: 0, null: false
      t.datetime :escalated_at
      t.datetime :last_message_at
      t.bigint   :telegram_chat_id
      t.bigint   :telegram_message_id
      t.jsonb    :metadata, default: {}, null: false
      t.timestamps
    end

    add_index :conversations, :visitor_token
    add_index :conversations, :status
    add_index :conversations, :telegram_message_id,
              unique: true, where: 'telegram_message_id IS NOT NULL'

    create_table :chat_messages do |t|
      t.references :conversation, foreign_key: true, null: false
      t.integer    :role, null: false
      t.text       :body, null: false
      t.references :author, foreign_key: { to_table: :users }
      t.bigint     :telegram_message_id
      t.jsonb      :metadata, default: {}, null: false
      t.timestamps
    end

    add_index :chat_messages, [:conversation_id, :created_at]
  end
end
