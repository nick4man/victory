# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Referrals::AutoCreator do
  # We build inquiries via factory which stubs callbacks except auto_create_referral.
  # AutoCreator is called explicitly in these specs — not via Inquiry#after_create_commit.

  # Helper to build a fully-saved inquiry linked to the given listing,
  # without firing the real auto_create_referral callback.
  def create_inquiry_for(external_listing)
    create(:inquiry, :with_external_listing, external_listing: external_listing)
  end

  # -----------------------------------------------------------------------
  # Happy path — agency matched via fallback source key
  # -----------------------------------------------------------------------
  describe 'happy path: inquiry with external_listing + matching PartnerAgency' do
    let!(:agency) do
      create(:partner_agency,
             feed_source_key: 'yandex_yrl',
             default_commission_rate: 0.30,
             status: 'active')
    end
    let!(:listing) { create(:external_listing, source: 'yandex_yrl') }
    let!(:inquiry) { create_inquiry_for(listing) }

    subject(:result) { described_class.call(inquiry) }

    it 'returns a successful result' do
      expect(result.ok?).to be(true)
    end

    it 'creates exactly one Referral' do
      expect { result }.to change(Referral.unscoped, :count).by(1)
    end

    it 'sets referral status to pending' do
      expect(result.referral.status).to eq('pending')
    end

    it 'copies agency default_commission_rate onto the referral' do
      expect(result.referral.commission_rate).to eq(0.30)
    end

    it 'links referral to the correct inquiry' do
      expect(result.referral.inquiry_id).to eq(inquiry.id)
    end

    it 'links referral to the matched agency' do
      expect(result.referral.partner_agency_id).to eq(agency.id)
    end

    it 'links referral to the external_listing' do
      expect(result.referral.external_listing_id).to eq(listing.id)
    end

    it 'stores auto_created_at and source in metadata' do
      meta = result.referral.metadata
      expect(meta['source']).to eq('yandex_yrl')
      expect(meta['auto_created_at']).to be_present
    end
  end

  # -----------------------------------------------------------------------
  # Match via agency_sitemap source_id prefix
  # -----------------------------------------------------------------------
  describe 'agency_sitemap match by source_id prefix' do
    let!(:agency) do
      create(:partner_agency, feed_source_key: 'cian_961', status: 'active',
                              default_commission_rate: 0.25)
    end
    let!(:listing) do
      create(:external_listing, source: 'agency_sitemap', source_id: 'cian_961:listing-987')
    end
    let!(:inquiry) { create_inquiry_for(listing) }

    it 'creates referral matched via source_id prefix' do
      result = described_class.call(inquiry)
      expect(result.ok?).to be(true)
      expect(result.referral.partner_agency_id).to eq(agency.id)
    end
  end

  # -----------------------------------------------------------------------
  # Match via yandex_yrl URL host
  # -----------------------------------------------------------------------
  describe 'yandex_yrl match by URL host' do
    let!(:agency) do
      create(:partner_agency, feed_source_key: 'cian.ru', status: 'active',
                              default_commission_rate: 0.20)
    end
    let!(:listing) do
      create(:external_listing, source: 'yandex_yrl',
             source_id: 'yrl-unique-host-123',
             url: 'https://cian.ru/sale/flat/300229777/')
    end
    let!(:inquiry) { create_inquiry_for(listing) }

    it 'creates referral matched via URL host' do
      result = described_class.call(inquiry)
      expect(result.ok?).to be(true)
      expect(result.referral.partner_agency_id).to eq(agency.id)
    end
  end

  # -----------------------------------------------------------------------
  # Idempotency — duplicate call must NOT create a second referral
  # -----------------------------------------------------------------------
  describe 'idempotency' do
    let!(:agency) do
      create(:partner_agency, feed_source_key: 'yandex_yrl', status: 'active')
    end
    let!(:listing) { create(:external_listing, source: 'yandex_yrl') }
    let!(:inquiry) { create_inquiry_for(listing) }

    before { described_class.call(inquiry) } # first call

    it 'returns skipped result on second call' do
      result = described_class.call(inquiry)
      expect(result.ok?).to be(false)
      expect(result.skipped_reason).to include('referral already exists')
    end

    it 'does not create a duplicate Referral record' do
      expect { described_class.call(inquiry) }.not_to change(Referral.unscoped, :count)
    end
  end

  # -----------------------------------------------------------------------
  # Edge: inquiry WITHOUT external_listing → noop
  # -----------------------------------------------------------------------
  describe 'edge: inquiry has no external_listing' do
    let!(:inquiry) { create(:inquiry) } # no :with_external_listing trait

    it 'returns unsuccessful skipped result' do
      result = described_class.call(inquiry)
      expect(result.ok?).to be(false)
      expect(result.skipped_reason).to include('no external_listing')
    end

    it 'does not create any Referral' do
      expect { described_class.call(inquiry) }.not_to change(Referral.unscoped, :count)
    end
  end

  # -----------------------------------------------------------------------
  # Edge: external_listing exists but NO matching PartnerAgency → noop
  # -----------------------------------------------------------------------
  describe 'edge: external_listing with no matching PartnerAgency' do
    let!(:listing) { create(:external_listing, source: 'avito') }
    let!(:inquiry) { create_inquiry_for(listing) }

    # Ensure no agency has feed_source_key='avito'
    before { PartnerAgency.unscoped.delete_all }

    it 'returns skipped result' do
      result = described_class.call(inquiry)
      expect(result.ok?).to be(false)
      expect(result.skipped_reason).to include('no PartnerAgency matched')
    end

    it 'does not create any Referral' do
      expect { described_class.call(inquiry) }.not_to change(Referral.unscoped, :count)
    end
  end

  # -----------------------------------------------------------------------
  # Edge: PartnerAgency found but BLOCKED → skip
  # -----------------------------------------------------------------------
  describe 'edge: matched PartnerAgency is blocked' do
    let!(:agency) do
      create(:partner_agency, feed_source_key: 'avito', status: 'blocked')
    end
    let!(:listing) { create(:external_listing, source: 'avito') }
    let!(:inquiry) { create_inquiry_for(listing) }

    it 'returns skipped result' do
      result = described_class.call(inquiry)
      expect(result.ok?).to be(false)
      expect(result.skipped_reason).to include('not claimable')
    end

    it 'does not create any Referral' do
      expect { described_class.call(inquiry) }.not_to change(Referral.unscoped, :count)
    end
  end

  # -----------------------------------------------------------------------
  # Edge: PartnerAgency found but INACTIVE → skip
  # -----------------------------------------------------------------------
  describe 'edge: matched PartnerAgency is inactive' do
    let!(:agency) do
      create(:partner_agency, feed_source_key: 'cian', status: 'inactive')
    end
    let!(:listing) { create(:external_listing, source: 'cian') }
    let!(:inquiry) { create_inquiry_for(listing) }

    it 'returns skipped result for inactive agency' do
      result = described_class.call(inquiry)
      expect(result.ok?).to be(false)
      expect(result.skipped_reason).to include('not claimable')
    end
  end

  # -----------------------------------------------------------------------
  # Edge: partner_agency.default_commission_rate is nil → referral created
  # with nil commission_rate (no fallback hardcoded in service)
  # -----------------------------------------------------------------------
  describe 'edge: agency has no default_commission_rate (nil)' do
    let!(:agency) do
      create(:partner_agency, feed_source_key: 'topnlab_mls',
             status: 'active', default_commission_rate: nil)
    end
    let!(:listing) { create(:external_listing, source: 'topnlab_mls') }
    let!(:inquiry) { create_inquiry_for(listing) }

    it 'creates referral successfully (nil rate is acceptable)' do
      result = described_class.call(inquiry)
      expect(result.ok?).to be(true)
    end

    it 'stores nil commission_rate on the referral (no magic fallback)' do
      result = described_class.call(inquiry)
      expect(result.referral.commission_rate).to be_nil
    end
  end

  # -----------------------------------------------------------------------
  # Result struct shape
  # -----------------------------------------------------------------------
  describe 'Result struct' do
    let!(:agency) { create(:partner_agency, feed_source_key: 'yandex_yrl', status: 'active') }
    let!(:listing) { create(:external_listing, source: 'yandex_yrl') }
    let!(:inquiry) { create_inquiry_for(listing) }

    it 'exposes .ok?, .referral, .skipped_reason' do
      result = described_class.call(inquiry)
      expect(result).to respond_to(:ok?, :referral, :skipped_reason)
    end

    it 'has nil skipped_reason on success' do
      result = described_class.call(inquiry)
      expect(result.skipped_reason).to be_nil
    end
  end
end
