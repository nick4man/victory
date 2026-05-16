# frozen_string_literal: true

# Magic-link auth для /cabinet — без Devise, без password.
# Token expires в 30 мин, single-use (consumed_at set after verify).
# identifier_type разделяет email-flow (ActionMailer) от phone-flow
# (Phase 2 — SMS gateway). Audit: ip_address + user_agent при generate.
class CreateMagicLinkTokens < ActiveRecord::Migration[7.1]
  def change
    create_table :magic_link_tokens do |t|
      t.string  :token,           null: false
      t.string  :identifier,      null: false
      t.string  :identifier_type, null: false
      t.datetime :expires_at,     null: false
      t.datetime :consumed_at
      t.string  :ip_address
      t.string  :user_agent
      t.timestamps
    end

    add_index :magic_link_tokens, :token, unique: true
    add_index :magic_link_tokens, :identifier
    add_index :magic_link_tokens, :expires_at
  end
end
