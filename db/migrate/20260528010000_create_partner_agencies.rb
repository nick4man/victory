# frozen_string_literal: true

# Phase 3 MLS/YRL — partner agencies (the OTHER агентства whose listings мы
# показываем через ExternalListing). Holds:
#   • Identifying info (name, slug, ОГРН stored в notes if needed)
#   • Contact channels (email/phone/person — для quick reach when лид приходит)
#   • Commission rate (default per-agency, can override on Referral)
#   • Feed source key — связь к ExternalListing.source / source_id prefix
#
# Match logic (Referrals::AutoCreator):
#   1. ExternalListing.source = 'agency_sitemap', source_id 'cian_961:...'
#      → PartnerAgency.find_by(feed_source_key: 'cian_961')
#   2. ExternalListing.source = 'cian' (aggregator scrape) → 'cian'
#   3. ExternalListing.source = 'yandex_yrl' → match by source_id host
#
# Soft-delete via `deleted_at` — consistent с victory62 convention.
class CreatePartnerAgencies < ActiveRecord::Migration[7.1]
  def change
    create_table :partner_agencies do |t|
      t.string  :name,                null: false
      t.string  :slug,                null: false
      t.string  :feed_source_key                                # matches ExternalListing source/agency_key
      t.string  :contact_email
      t.string  :contact_phone
      t.string  :contact_person
      t.decimal :default_commission_rate, precision: 5, scale: 4 # 0.0000..1.0000 (e.g. 0.30 = 30%)
      t.string  :settlement_terms                                # «net 30 after closing» etc.
      t.text    :notes
      t.string  :status, default: 'active'                       # active | inactive | blocked
      t.jsonb   :metadata, default: {}
      t.datetime :deleted_at
      t.timestamps
    end

    add_index :partner_agencies, :slug,            unique: true
    add_index :partner_agencies, :feed_source_key, where: 'feed_source_key IS NOT NULL'
    add_index :partner_agencies, :deleted_at,      where: 'deleted_at IS NOT NULL'
  end
end
