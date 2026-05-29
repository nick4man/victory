# frozen_string_literal: true

# D5 — «Contract before publish» gate (см. plan «Catalog Polish + Client
# Onboarding»).
#
# Adds Property.signed_agency_contract_at — timestamp когда client
# подписал agency contract через /cabinet/listings/:id/consent. Required
# чтобы property оказался на сайте.
#
# CRITICAL: existing 26 published properties были созданы ДО введения
# A7 Phase 3 ListingConsent flow. Backfill grandfather'ит их —
# используем published_at как proxy («когда впервые согласилось АН
# показывать»). Без backfill new gate срежет их с сайта.
class AddSignedAgencyContractAtToProperties < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def up
    add_column :properties, :signed_agency_contract_at, :datetime, null: true unless column_exists?(:properties, :signed_agency_contract_at)
    add_index  :properties, :signed_agency_contract_at,
               where: 'signed_agency_contract_at IS NOT NULL',
               algorithm: :concurrently,
               if_not_exists: true

    # Grandfather: existing published properties — they were live before
    # the contract gate. Set signed_agency_contract_at = published_at
    # так что ready_for_site? отвечает true → они остаются on_site.
    say_with_time 'Backfill signed_agency_contract_at для published properties' do
      execute(<<~SQL)
        UPDATE properties
        SET signed_agency_contract_at = published_at
        WHERE status = #{ActiveRecord::Base.connection.quote(Property.statuses[:active])}
          AND published_at IS NOT NULL
          AND signed_agency_contract_at IS NULL
      SQL
    end
  end

  def down
    remove_index  :properties, :signed_agency_contract_at, if_exists: true
    remove_column :properties, :signed_agency_contract_at, if_exists: true
  end
end
