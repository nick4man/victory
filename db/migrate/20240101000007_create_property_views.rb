# frozen_string_literal: true

class CreatePropertyViews < ActiveRecord::Migration[7.1]
  def change
    create_table :property_views do |t|
      # Associations
      t.references :user, foreign_key: true, index: true
      t.references :property, null: false, foreign_key: true, index: true
      
      # View details
      t.datetime :viewed_at, null: false, default: -> { 'CURRENT_TIMESTAMP' }
      t.integer :duration_seconds # Время просмотра в секундах
      
      # Tracking
      t.string :ip_address
      t.string :user_agent
      t.string :referrer_url
      t.string :session_id
      
      # Device info
      t.string :device_type # mobile, tablet, desktop
      t.string :browser
      t.string :os
      
      # Source tracking
      t.string :source # direct, search, social, email, ad
      t.string :utm_source
      t.string :utm_medium
      t.string :utm_campaign
      t.string :utm_term
      t.string :utm_content
      
      # Page interaction
      t.boolean :viewed_phone, default: false
      t.boolean :viewed_images, default: false
      t.boolean :viewed_map, default: false
      t.boolean :viewed_virtual_tour, default: false
      t.integer :images_viewed_count, default: 0
      
      # Actions taken
      t.boolean :contacted_owner, default: false
      t.boolean :added_to_favorites, default: false
      t.boolean :shared, default: false
      
      # Geographic
      t.string :country_code
      t.string :city
      t.decimal :latitude, precision: 10, scale: 6
      t.decimal :longitude, precision: 10, scale: 6
      
      # Metadata
      t.jsonb :metadata, default: {}
      
      t.timestamps
    end
    
    # Indexes for performance
    add_index :property_views, [:property_id, :viewed_at]
    add_index :property_views, [:user_id, :viewed_at]
    add_index :property_views, [:user_id, :property_id]
    add_index :property_views, :session_id
    add_index :property_views, :viewed_at
    add_index :property_views, :source
    add_index :property_views, :device_type
    add_index :property_views, :created_at
    
    # Compound indexes for analytics
    add_index :property_views, [:property_id, :created_at, :user_id]
    add_index :property_views, [:viewed_at, :property_id]
    add_index :property_views, [:user_id, :property_id, :viewed_at], 
              name: 'index_property_views_on_user_property_date'
  end
end