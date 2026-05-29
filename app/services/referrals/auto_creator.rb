# frozen_string_literal: true

module Referrals
  # Phase 3 MLS/YRL — fires from Inquiry after_create_commit когда
  # `external_listing_id` present. Match'ит external_listing → PartnerAgency
  # → создаёт `Referral(status: 'pending')`.
  #
  # Match logic — приоритет (first hit wins):
  #   1. ExternalListing.source = 'agency_sitemap', source_id = 'cian_961:abc...'
  #      → PartnerAgency.where(feed_source_key: 'cian_961').first
  #   2. ExternalListing.source = 'yandex_yrl' и source_id host known
  #      → match by feed_source_key (host).
  #   3. Fallback to ExternalListing.source enum value
  #      ('cian', 'avito', 'topnlab_mls').
  #
  # Если PartnerAgency не найдена — НЕ создаём referral, логируем warning.
  # Admin может позже manual-create через UI.
  #
  # Если PartnerAgency blocked — skip (см. PartnerAgency#claimable?).
  class AutoCreator
    Result = Struct.new(:ok?, :referral, :skipped_reason, keyword_init: true)

    def self.call(inquiry)
      new(inquiry).call
    end

    def initialize(inquiry)
      @inquiry = inquiry
    end

    def call
      external = @inquiry.external_listing
      return skip('inquiry has no external_listing') if external.blank?
      return skip('referral already exists') if Referral.exists?(inquiry_id: @inquiry.id)

      agency = match_agency(external)
      return skip("no PartnerAgency matched for source=#{external.source}") if agency.nil?
      return skip("agency #{agency.slug} not claimable (status=#{agency.status})") unless agency.claimable?

      referral = Referral.create!(
        inquiry:           @inquiry,
        partner_agency:    agency,
        external_listing:  external,
        commission_rate:   agency.default_commission_rate,
        status:            'pending',
        metadata:          { 'auto_created_at' => Time.current.iso8601, 'source' => external.source }
      )
      Rails.logger.info(
        "[Referrals::AutoCreator] created referral=#{referral.id} " \
        "inquiry=#{@inquiry.id} agency=#{agency.slug} listing=#{external.id}"
      )
      Result.new(ok?: true, referral: referral, skipped_reason: nil)
    end

    private

    def skip(reason)
      Rails.logger.info("[Referrals::AutoCreator] inquiry=#{@inquiry.id} skipped: #{reason}")
      Result.new(ok?: false, referral: nil, skipped_reason: reason)
    end

    # Match priority — see class doc.
    def match_agency(external)
      # 1. agency_sitemap: source_id префикс = agency_key
      if external.source == 'agency_sitemap' && external.source_id.present?
        agency_key = external.source_id.to_s.split(':').first
        if agency_key.present?
          agency = PartnerAgency.where(feed_source_key: agency_key).first
          return agency if agency
        end
      end

      # 2. yandex_yrl: match by source_id host (если хранится как URL)
      if external.source == 'yandex_yrl' && external.url.present?
        host = URI.parse(external.url).host rescue nil
        if host
          agency = PartnerAgency.where(feed_source_key: host).first
          return agency if agency
        end
      end

      # 3. fallback: ExternalListing.source as feed_source_key
      PartnerAgency.where(feed_source_key: external.source).first
    end
  end
end
