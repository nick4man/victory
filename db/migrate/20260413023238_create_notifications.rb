# frozen_string_literal: true

class CreateNotifications < ActiveRecord::Migration[7.1]
  def change
    create_table :notifications do |t|
      t.references :user,       null: false, foreign_key: true
      t.string     :notifiable_type
      t.bigint     :notifiable_id
      t.string     :notification_type, null: false
      t.string     :title,            null: false
      t.text       :body
      t.string     :link
      t.datetime   :read_at

      t.timestamps
    end

    add_index :notifications, [:notifiable_type, :notifiable_id]
    add_index :notifications, [:user_id, :read_at]
    add_index :notifications, :notification_type
  end
end
