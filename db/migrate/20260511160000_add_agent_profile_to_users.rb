# frozen_string_literal: true

# Agent-specific fields for /agents/:slug profile pages (B3 from v4.0 plan).
# Only populated for users with role = agent; other roles get nulls/defaults.
#
# agent_slug — FriendlyId-style URL slug, transliterated from full name.
#   Unique only where present (NULL allowed for non-agent users).
class AddAgentProfileToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :agent_slug,            :string
    add_column :users, :deals_closed_count,    :integer, default: 0, null: false
    add_column :users, :response_time_minutes, :integer
    add_column :users, :languages,             :jsonb,   default: []
    add_column :users, :specialties,           :jsonb,   default: []
    add_column :users, :license_no,            :string

    # Partial unique index — only enforce uniqueness for agents (non-null slugs).
    add_index :users, :agent_slug, unique: true, where: 'agent_slug IS NOT NULL'
  end
end
