# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PartnerAgency, type: :model do
  # -----------------------------------------------------------------------
  # Associations
  # -----------------------------------------------------------------------
  describe 'associations' do
    it { is_expected.to have_many(:referrals).dependent(:nullify) }
  end

  # -----------------------------------------------------------------------
  # Validations
  # -----------------------------------------------------------------------
  describe 'validations' do
    subject(:agency) { build(:partner_agency) }

    it 'is valid with minimal required attributes' do
      expect(agency).to be_valid
    end

    it { is_expected.to validate_presence_of(:name) }

    it 'rejects name longer than 200 chars' do
      agency.name = 'А' * 201
      expect(agency).not_to be_valid
      expect(agency.errors[:name]).to be_present
    end

    it { is_expected.to validate_presence_of(:slug) }

    it 'enforces slug uniqueness' do
      create(:partner_agency, slug: 'test-slug')
      dup = build(:partner_agency, slug: 'test-slug')
      expect(dup).not_to be_valid
      expect(dup.errors[:slug]).to be_present
    end

    it 'rejects slug with uppercase letters' do
      agency.slug = 'Bad-Slug'
      expect(agency).not_to be_valid
      expect(agency.errors[:slug]).to be_present
    end

    it 'rejects slug with spaces' do
      agency.slug = 'has space'
      expect(agency).not_to be_valid
    end

    it 'accepts slug with lowercase, digits, hyphens and underscores' do
      agency.slug = 'good_slug-123'
      expect(agency).to be_valid
    end

    it 'rejects status outside STATUSES' do
      agency.status = 'suspended'
      expect(agency).not_to be_valid
      expect(agency.errors[:status]).to be_present
    end

    it 'accepts each member of STATUSES' do
      described_class::STATUSES.each do |s|
        expect(build(:partner_agency, status: s)).to be_valid
      end
    end

    it 'rejects default_commission_rate below 0' do
      agency.default_commission_rate = -0.01
      expect(agency).not_to be_valid
    end

    it 'rejects default_commission_rate above 1' do
      agency.default_commission_rate = 1.01
      expect(agency).not_to be_valid
    end

    it 'accepts default_commission_rate of nil (optional)' do
      agency.default_commission_rate = nil
      expect(agency).to be_valid
    end

    it 'accepts commission rate on [0, 1] boundary values' do
      expect(build(:partner_agency, default_commission_rate: 0)).to be_valid
      expect(build(:partner_agency, default_commission_rate: 1)).to be_valid
    end

    it 'rejects malformed contact_email' do
      agency.contact_email = 'not-an-email'
      expect(agency).not_to be_valid
      expect(agency.errors[:contact_email]).to be_present
    end

    it 'accepts blank contact_email' do
      agency.contact_email = ''
      expect(agency).to be_valid
    end

    it 'accepts valid contact_email' do
      agency.contact_email = 'partner@agency.ru'
      expect(agency).to be_valid
    end
  end

  # -----------------------------------------------------------------------
  # Scopes
  # -----------------------------------------------------------------------
  describe 'scopes' do
    let!(:active_agency)   { create(:partner_agency, status: 'active') }
    let!(:inactive_agency) { create(:partner_agency, status: 'inactive') }
    let!(:keyed_agency)    { create(:partner_agency, feed_source_key: 'cian_961') }

    describe '.active' do
      it 'returns only active agencies' do
        expect(described_class.active).to include(active_agency)
        expect(described_class.active).not_to include(inactive_agency)
      end
    end

    describe '.with_feed_key' do
      it 'returns agencies matching the given feed_source_key' do
        expect(described_class.with_feed_key('cian_961')).to include(keyed_agency)
      end

      it 'returns nothing for unknown key' do
        expect(described_class.with_feed_key('unknown')).to be_empty
      end
    end
  end

  # -----------------------------------------------------------------------
  # Soft delete
  # -----------------------------------------------------------------------
  describe 'soft delete' do
    let!(:agency) { create(:partner_agency) }

    it 'sets deleted_at on destroy' do
      expect { agency.destroy }.to change { agency.reload.deleted_at }.from(nil)
    end

    it 'excludes deleted records from default scope' do
      agency.destroy
      expect(described_class.where(id: agency.id)).to be_empty
    end

    it 'makes deleted records accessible via unscoped' do
      agency.destroy
      expect(described_class.unscoped.where(id: agency.id)).to exist
    end

    it 'does not decrement count in DB' do
      expect { agency.destroy }.not_to change { described_class.unscoped.count }
    end
  end

  # -----------------------------------------------------------------------
  # Instance methods
  # -----------------------------------------------------------------------
  describe '#display_label' do
    it 'shows name only when no commission rate set' do
      agency = build(:partner_agency, name: 'ЦАН', default_commission_rate: nil)
      expect(agency.display_label).to eq('ЦАН')
    end

    it 'appends commission percentage when rate is present' do
      agency = build(:partner_agency, name: 'ЦАН', default_commission_rate: 0.30)
      expect(agency.display_label).to eq('ЦАН · 30%')
    end

    it 'handles fractional rate correctly (rounds down to integer percent)' do
      agency = build(:partner_agency, name: 'ЦАН', default_commission_rate: 0.255)
      # (0.255 * 100).to_i = 25
      expect(agency.display_label).to eq('ЦАН · 25%')
    end
  end

  describe '#claimable?' do
    it 'returns true for active non-deleted agency' do
      expect(build(:partner_agency, status: 'active', deleted_at: nil)).to be_claimable
    end

    it 'returns false for inactive agency' do
      expect(build(:partner_agency, status: 'inactive')).not_to be_claimable
    end

    it 'returns false for blocked agency' do
      expect(build(:partner_agency, status: 'blocked')).not_to be_claimable
    end

    it 'returns false when deleted_at is set even if status=active' do
      expect(build(:partner_agency, status: 'active', deleted_at: 1.hour.ago)).not_to be_claimable
    end
  end
end
