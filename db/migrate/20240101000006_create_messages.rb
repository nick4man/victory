# frozen_string_literal: true

class CreateMessages < ActiveRecord::Migration[7.1]
  def change
    create_table :messages do |t|
      # Associations
      t.references :sender, null: false, foreign_key: { to_table: :users }, index: true
      t.references :recipient, null: false, foreign_key: { to_table: :users }, index: true
      
      # Related entities
      t.references :property, foreign_key: true, index: true
      t.references :inquiry, foreign_key: true, index: true
      
      # Conversation threading
      t.string :conversation_id, null: false
      t.references :parent, foreign_key: { to_table: :messages }, index: true
      
      # Message content
      t.string :subject
      t.text :body, null: false
      
      # Message type
      t.integer :message_type, default: 0, null: false
      # 0: regular, 1: system, 2: notification, 3: automated
      
      # Status
      t.boolean :read, default: false, null: false
      t.datetime :read_at
      
      t.boolean :archived_by_sender, default: false
      t.boolean :archived_by_recipient, default: false
      
      t.boolean :deleted_by_sender, default: false
      t.boolean :deleted_by_recipient, default: false
      
      # Priority
      t.integer :priority, default: 0, null: false
      # 0: normal, 1: high, 2: urgent
      
      # Attachments metadata
      t.integer :attachments_count, default: 0, null: false
      t.jsonb :attachments_metadata, default: {}
      
      # Tracking
      t.string :ip_address
      t.string :user_agent
      
      # System fields
      t.boolean :is_automated, default: false, null: false
      t.string :automated_template
      
      # Metadata
      t.jsonb :metadata, default: {}
      
      t.timestamps
    end
    
    # Indexes for performance
    add_index :messages, :conversation_id
    add_index :messages, [:sender_id, :created_at]
    add_index :messages, [:recipient_id, :created_at]
    add_index :messages, [:sender_id, :read]
    add_index :messages, [:recipient_id, :read]
    add_index :messages, [:conversation_id, :created_at]
    add_index :messages, [:read, :recipient_id]
    add_index :messages, :message_type
    add_index :messages, :priority
    add_index :messages, :created_at
    
    # Compound indexes for common queries
    add_index :messages, [:recipient_id, :read, :created_at]
    add_index :messages, [:conversation_id, :parent_id, :created_at]
    add_index :messages, [:deleted_by_sender, :deleted_by_recipient]
  end
end