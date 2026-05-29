# frozen_string_literal: true

# Phase 2 of MLS/YRL plan — когда client submit'ит Inquiry на чужой объект
# (через /external-listings/:id form), сохраняем reference на ExternalListing.
# Используется для:
#   1. Auto-create Referral (Phase 3) — match inquiry → partner agency
#   2. Admin UI — фильтр «лиды на чужие объекты»
#   3. Lead-routing logic в LeadAssignment
#
# Nullable: огромное большинство Inquiry — на наши properties (property_id),
# external_listing_id stays NULL.
class AddExternalListingIdToInquiries < ActiveRecord::Migration[7.1]
  def change
    add_reference :inquiries, :external_listing,
                  null: true,
                  index: { where: 'external_listing_id IS NOT NULL' },
                  foreign_key: { on_delete: :nullify }
  end
end
