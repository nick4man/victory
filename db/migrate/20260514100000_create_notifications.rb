# frozen_string_literal: true

# In-app notification feed shown at /dashboard/notifications. Every key
# event for a user (inquiry confirmed, valuation ready, property matches a
# saved search, etc.) inserts a row here; the dashboard renders the unread
# count in the nav and the full list on the index page.
#
# `notifiable` is polymorphic so the same row links back to whatever caused
# it — Inquiry, PropertyValuation, Property, Article — without a separate
# join table per type.
#
# `read_at IS NULL` = unread. We don't delete; we soft-clear by archiving
# (User#clear_all sets archived_at) so audit/analytics still see history.
class CreateNotifications < ActiveRecord::Migration[7.1]
  def change
    create_table :notifications do |t|
      t.references :user, null: false, foreign_key: true, index: true
      t.string  :kind,  null: false   # 'inquiry' / 'valuation' / 'property_match' / 'message' / 'system'
      t.string  :title, null: false
      t.text    :body
      t.string  :url
      t.references :notifiable, polymorphic: true, null: true, index: true
      t.datetime :read_at,     index: true
      t.datetime :archived_at, index: true
      t.timestamps
    end

    # Hot path: «unread for this user, newest first». Compound index covers it.
    add_index :notifications, %i[user_id read_at created_at]
  end
end
