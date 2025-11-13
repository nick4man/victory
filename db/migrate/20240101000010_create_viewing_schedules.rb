# frozen_string_literal: true

class CreateViewingSchedules < ActiveRecord::Migration[7.0]
  def change
    create_table :viewing_schedules do |t|
      # Associations
      t.references :property, null: false, foreign_key: true, index: true
      t.references :user, null: false, foreign_key: true, index: true # client
      t.references :agent, foreign_key: { to_table: :users }, index: true
      t.references :inquiry, null: true, foreign_key: true, index: true

      # Viewing details
      t.datetime :scheduled_at, null: false
      t.datetime :ends_at
      t.integer :duration, default: 60 # in minutes
      
      # Contact info
      t.string :name, null: false
      t.string :phone, null: false
      t.string :email
      
      # Additional info
      t.text :notes
      t.text :agent_notes
      t.string :viewing_type, default: 'in_person' # in_person, online, video_call
      t.string :meeting_link # for online viewings
      
      # Status
      t.string :status, default: 'scheduled', null: false 
      # scheduled, confirmed, completed, cancelled, no_show
      
      # Notifications
      t.boolean :reminder_sent, default: false, null: false
      t.datetime :reminder_sent_at
      
      # Confirmation
      t.datetime :confirmed_at
      t.string :confirmation_token
      
      # Completion
      t.datetime :completed_at
      t.text :completion_notes
      t.integer :rating # 1-5
      t.text :feedback
      
      # Cancellation
      t.datetime :cancelled_at
      t.string :cancellation_reason
      t.text :cancellation_notes
      
      t.timestamps
      t.datetime :deleted_at
    end

    # Indexes
    add_index :viewing_schedules, :scheduled_at
    add_index :viewing_schedules, :status
    add_index :viewing_schedules, :viewing_type
    add_index :viewing_schedules, :confirmation_token, unique: true
    add_index :viewing_schedules, :deleted_at
    add_index :viewing_schedules, [:property_id, :scheduled_at]
    add_index :viewing_schedules, [:user_id, :scheduled_at]
    add_index :viewing_schedules, [:agent_id, :scheduled_at]
    add_index :viewing_schedules, [:scheduled_at, :status]
  end
end

