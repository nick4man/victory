# frozen_string_literal: true

# A7 Phase 3: digital agency contract signing.
# Client signs consent → ListingConsent record (legal proof) + Property
# flips status pending_consent → active.
#
# Audit fields (IP, UA, signed_at, content hash) — legal proof для
# случая dispute. consent_text — full agreement copy на момент signing
# (агентский договор может evolve версиями, fix'аем what was signed).
# token — для QR-verify URL: /verify-contract/:token.
class CreateListingConsents < ActiveRecord::Migration[7.1]
  def change
    create_table :listing_consents do |t|
      t.references :property, null: false, foreign_key: true
      t.references :user,     null: false, foreign_key: true
      t.string   :token,           null: false
      t.datetime :signed_at,       null: false
      t.text     :consent_text,    null: false
      t.string   :consent_version, null: false # e.g., "v1-2026-05-17"
      t.string   :content_hash,    null: false # SHA-256 of consent_text для tamper-detection
      t.string   :ip_address
      t.string   :user_agent
      t.datetime :revoked_at
      t.string   :revocation_reason

      t.timestamps
    end

    add_index :listing_consents, :token, unique: true
    add_index :listing_consents, %i[property_id user_id]
    add_index :listing_consents, :signed_at
  end
end
