# frozen_string_literal: true

class CreateSavedSearches < ActiveRecord::Migration[7.1]
  def change
    create_table :saved_searches do |t|
      # Associations
      t.references :user, null: false, foreign_key: true, index: true
      
      # Search details
      t.string :name, null: false
      t.text :description
      
      # Search filters (stored as JSON)
      t.jsonb :filters, null: false, default: {}
      
      # Search URL for quick access
      t.text :search_url
      
      # Status
      t.boolean :active, default: true, null: false
      
      # Notifications
      t.boolean :notify_enabled, default: true, null: false
      t.integer :notification_frequency, default: 0, null: false
      # 0: immediately, 1: daily, 2: weekly, 3: never
      
      t.datetime :last_checked_at
      t.datetime :last_notification_sent_at
      
      # Results tracking
      t.integer :results_count, default: 0, null: false
      t.integer :new_results_count, default: 0, null: false
      t.datetime :last_results_count_updated_at
      
      # Usage statistics
      t.integer :clicks_count, default: 0, null: false
      t.datetime :last_used_at
      
      # Metadata
      t.jsonb :metadata, default: {}
      
      # Sorting
      t.integer :position, default: 0, null: false
      
      t.timestamps
    end
    
    # Indexes for performance
    add_index :saved_searches, :active
    add_index :saved_searches, :notify_enabled
    add_index :saved_searches, :last_checked_at
    add_index :saved_searches, [:user_id, :active]
    add_index :saved_searches, [:user_id, :created_at]
    add_index :saved_searches, :filters, using: :gin
    add_index :saved_searches, :created_at
  end
end