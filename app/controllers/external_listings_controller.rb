# frozen_string_literal: true

# Show pages для чужих объектов недвижимости (других агентств / открытых
# фидов). Phase 2 of MLS/YRL plan.
#
# Architecture:
#   - Index = НЕ публичный route. External cards рендерятся в общем
#     /properties index (через PropertiesController), не на отдельной странице.
#   - Show = /external-listings/:id — короткая landing страница с:
#       • фото, цена, описание из ExternalListing
#       • lead-capture form (Inquiry с external_listing_id)
#       • rel="canonical" → наш URL (не external), мы re-publishим openly
#       • JSON-LD RealEstateListing с агентством-источником как seller
#
# Lead path: form submit → InquiriesController#create → Inquiry с
# external_listing_id → Phase 3 routes к partner agency via Referral.
class ExternalListingsController < ApplicationController
  before_action :set_external_listing

  def show
    @host = request.host_with_port
    build_meta_tags
    fresh_when(@external_listing, public: true)
  end

  private

  def set_external_listing
    @external_listing = ExternalListing.active.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to properties_path, alert: 'Объект больше недоступен. Посмотрите другие предложения.'
  end

  # SEO: canonical → наш URL (не external). Тэги OG для социалок.
  def build_meta_tags
    @canonical_url = external_listing_url(@external_listing)
    @meta_title    = "#{@external_listing.title.to_s.truncate(60)} — АН «Виктори»"
    @meta_description = build_description
  end

  def build_description
    parts = [@external_listing.title]
    parts << "#{@external_listing.price.to_i} ₽" if @external_listing.price.to_f.positive?
    parts << @external_listing.address.to_s.truncate(80)
    parts << 'По данным открытого фида. Заявка через АН «Виктори».'
    parts.compact.join(' · ').truncate(200)
  end
end
