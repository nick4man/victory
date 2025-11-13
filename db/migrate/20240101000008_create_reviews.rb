# frozen_string_literal: true

class CreateReviews < ActiveRecord::Migration[7.1]
  def change
    create_table :reviews do |t|
      # Associations
      t.references :user, null: false, foreign_key: true, index: true
      t.references :property, foreign_key: true, index: true
      t.references :agent, foreign_key: { to_table: :users }, index: true
      
      # Review type
      t.integer :review_type, default: 0, null: false
      # 0: property_review, 1: agent_review, 2: service_review
      
      # Rating (1-5 stars)
      t.integer :rating, null: false
      
      # Detailed ratings (optional)
      t.integer :location_rating
      t.integer :value_rating
      t.integer :condition_rating
      t.integer :communication_rating
      t.integer :professionalism_rating
      
      # Review content
      t.string :title
      t.text :body, null: false
      t.text :pros
      t.text :cons
      
      # Status
      t.integer :status, default: 0, null: false
      # 0: pending, 1: approved, 2: rejected, 3: hidden
      
      # Moderation
      t.references :moderated_by, foreign_key: { to_table: :users }
      t.datetime :moderated_at
      t.text :moderation_notes
      t.string :rejection_reason
      
      # Response from owner/agent
      t.text :response
      t.references :responded_by, foreign_key: { to_table: :users }
      t.datetime :responded_at
      
      # Verification
      t.boolean :verified_purchase, default: false
      t.boolean :verified_client, default: false
      
      # Helpfulness
      t.integer :helpful_count, default: 0, null: false
      t.integer :not_helpful_count, default: 0, null: false
      
      # Images
      t.integer :images_count, default: 0, null: false
      
      # Flags and reports
      t.integer :reports_count, default: 0, null: false
      t.boolean :flagged, default: false
      
      # Visibility
      t.boolean :visible, default: true, null: false
      t.boolean :featured, default: false, null: false
      
      # Tracking
      t.string :ip_address
      t.string :user_agent
      
      # Source
      t.string :source # web, mobile, email, imported
      
      # Deal completion (for verified reviews)
      t.date :deal_date
      t.string :transaction_id
      
      # Metadata
      t.jsonb :metadata, default: {}
      
      # Publishing
      t.datetime :published_at
      
      t.timestamps
    end
    
    # Indexes for performance
    add_index :reviews, :review_type
    add_index :reviews, :rating
    add_index :reviews, :status
    add_index :reviews, :created_at
    add_index :reviews, :published_at
    add_index :reviews, :featured
    add_index :reviews, :verified_purchase
    add_index :reviews, :visible
    
    # Compound indexes
    add_index :reviews, [:property_id, :status, :rating]
    add_index :reviews, [:agent_id, :status, :rating]
    add_index :reviews, [:user_id, :created_at]
    add_index :reviews, [:status, :created_at]
    add_index :reviews, [:property_id, :status, :published_at]
    add_index :reviews, [:visible, :status, :rating]
    
    # Add constraints
    add_check_constraint :reviews, 'rating >= 1 AND rating <= 5', name: 'reviews_rating_range'
    add_check_constraint :reviews, 
      'location_rating IS NULL OR (location_rating >= 1 AND location_rating <= 5)', 
      name: 'reviews_location_rating_range'
    add_check_constraint :reviews, 
      'value_rating IS NULL OR (value_rating >= 1 AND value_rating <= 5)', 
      name: 'reviews_value_rating_range'
    add_check_constraint :reviews, 
      'condition_rating IS NULL OR (condition_rating >= 1 AND condition_rating <= 5)', 
      name: 'reviews_condition_rating_range'
  end
end