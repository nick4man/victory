# frozen_string_literal: true

class DeviseCreateUsers < ActiveRecord::Migration[7.1]
  def change
    create_table :users do |t|
      ## Database authenticatable
      t.string :email,              null: false, default: ""
      t.string :encrypted_password, null: false, default: ""

      ## Recoverable
      t.string   :reset_password_token
      t.datetime :reset_password_sent_at

      ## Rememberable
      t.datetime :remember_created_at

      ## Trackable
      t.integer  :sign_in_count, default: 0, null: false
      t.datetime :current_sign_in_at
      t.datetime :last_sign_in_at
      t.string   :current_sign_in_ip
      t.string   :last_sign_in_ip

      ## Confirmable
      t.string   :confirmation_token
      t.datetime :confirmed_at
      t.datetime :confirmation_sent_at
      t.string   :unconfirmed_email # Only if using reconfirmable

      ## Lockable
      t.integer  :failed_attempts, default: 0, null: false # Only if lock strategy is :failed_attempts
      t.string   :unlock_token # Only if unlock strategy is :email or :both
      t.datetime :locked_at

      ## User Information
      t.string :first_name
      t.string :last_name
      t.string :phone
      t.string :avatar_url
      
      ## Role
      t.integer :role, default: 0, null: false # 0: client, 1: agent, 2: admin
      
      ## OAuth
      t.string :provider
      t.string :uid
      
      ## Additional fields
      t.text :bio
      t.string :company
      t.string :position
      
      ## Preferences
      t.jsonb :notification_settings, default: {}
      t.jsonb :preferences, default: {}
      
      ## Stats
      t.integer :properties_count, default: 0, null: false
      t.integer :inquiries_count, default: 0, null: false
      t.integer :favorites_count, default: 0, null: false
      
      ## Status
      t.boolean :active, default: true, null: false
      t.datetime :last_activity_at
      
      ## Soft delete
      t.datetime :deleted_at

      t.timestamps null: false
    end

    add_index :users, :email,                unique: true
    add_index :users, :reset_password_token, unique: true
    add_index :users, :confirmation_token,   unique: true
    add_index :users, :unlock_token,         unique: true
    add_index :users, :phone,                unique: true
    add_index :users, [:provider, :uid],     unique: true
    add_index :users, :role
    add_index :users, :deleted_at
    add_index :users, :created_at
  end
end