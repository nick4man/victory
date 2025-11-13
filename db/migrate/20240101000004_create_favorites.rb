# frozen_string_literal: true

class CreateFavorites < ActiveRecord::Migration[7.1]
  def change
    create_table :favorites do |t|
      # Associations
      t.references :user, null: false, foreign_key: true, index: true
      t.references :property, null: false, foreign_key: true, index: true
      
      # Additional info
      t.text :note # Личная заметка пользователя
      
      # Notifications
      t.boolean :notify_on_price_change, default: true
      t.boolean :notify_on_status_change, default: true
      
      # Metadata
      t.string :source # web, mobile, api
      t.jsonb :metadata, default: {}
      
      t.timestamps
    end
    
    # Unique constraint - user can't favorite same property twice
    add_index :favorites, [:user_id, :property_id], unique: true
    
    # Index for finding all favorites of a property
    add_index :favorites, [:property_id, :created_at]
    
    # Index for recent favorites
    add_index :favorites, :created_at
  end
end