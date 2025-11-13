# frozen_string_literal: true

class CreateInquiries < ActiveRecord::Migration[7.1]
  def change
    create_table :inquiries do |t|
      # Associations
      t.references :user, foreign_key: true, index: true
      t.references :property, foreign_key: true, index: true
      t.references :agent, foreign_key: { to_table: :users }, index: true
      
      # Type and Status
      t.integer :inquiry_type, default: 0, null: false
      # 0: viewing, 1: consultation, 2: mortgage, 3: evaluation, 
      # 4: callback, 5: quick_inquiry, 6: contact_agent
      
      t.integer :status, default: 0, null: false
      # 0: new, 1: in_progress, 2: completed, 3: cancelled, 4: spam
      
      # Contact Information
      t.string :name, null: false
      t.string :phone, null: false
      t.string :email
      
      # Inquiry Details
      t.text :message
      t.text :comment # Комментарий менеджера
      
      # Scheduling (for viewing requests)
      t.datetime :preferred_date
      t.string :preferred_time
      t.datetime :scheduled_at
      t.datetime :completed_at
      
      # Additional data (JSONB for flexibility)
      t.jsonb :metadata, default: {}
      
      # Source tracking
      t.string :source # web, mobile, api, phone
      t.string :utm_source
      t.string :utm_medium
      t.string :utm_campaign
      t.string :referrer_url
      
      # IP and User Agent
      t.string :ip_address
      t.string :user_agent
      
      # Processing
      t.datetime :processed_at
      t.datetime :cancelled_at
      t.string :cancellation_reason
      
      # CRM Integration
      t.string :crm_id # ID в AmoCRM или другой CRM
      t.datetime :synced_to_crm_at
      
      # Priority
      t.integer :priority, default: 0 # 0: normal, 1: high, 2: urgent
      
      # Notifications
      t.boolean :notifications_sent, default: false
      t.datetime :last_notification_at
      
      t.timestamps
    end
    
    # Indexes for performance
    add_index :inquiries, :inquiry_type
    add_index :inquiries, :status
    add_index :inquiries, :phone
    add_index :inquiries, :email
    add_index :inquiries, :created_at
    add_index :inquiries, :preferred_date
    add_index :inquiries, :scheduled_at
    add_index :inquiries, :source
    add_index :inquiries, :crm_id
    add_index :inquiries, [:status, :inquiry_type]
    add_index :inquiries, [:user_id, :status]
    add_index :inquiries, [:property_id, :status]
    add_index :inquiries, [:created_at, :status]
  end
end