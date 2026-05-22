# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Referral, type: :model do
  # -----------------------------------------------------------------------
  # Associations
  # -----------------------------------------------------------------------
  describe 'associations' do
    it { is_expected.to belong_to(:inquiry) }
    it { is_expected.to belong_to(:partner_agency) }
    it { is_expected.to belong_to(:external_listing).optional }
  end

  # -----------------------------------------------------------------------
  # Validations
  # -----------------------------------------------------------------------
  describe 'validations' do
    subject(:referral) { build(:referral) }

    it 'is valid with minimal required attributes (pending state)' do
      expect(referral).to be_valid
    end

    it 'requires status' do
      referral.status = nil
      expect(referral).not_to be_valid
      expect(referral.errors[:status]).to be_present
    end

    it 'rejects status outside STATUSES' do
      referral.status = 'unknown_state'
      expect(referral).not_to be_valid
    end

    it 'accepts each member of STATUSES' do
      described_class::STATUSES.each do |s|
        r = build(:referral, status: s)
        # closed_won requires final_commission_amount — skip that here
        r.final_commission_amount = 100_000 if s == 'closed_won'
        expect(r).to be_valid, "expected status=#{s} to be valid"
      end
    end

    it 'rejects commission_rate below 0' do
      referral.commission_rate = -0.01
      expect(referral).not_to be_valid
    end

    it 'rejects commission_rate above 1' do
      referral.commission_rate = 1.01
      expect(referral).not_to be_valid
    end

    it 'accepts nil commission_rate' do
      referral.commission_rate = nil
      expect(referral).to be_valid
    end

    it 'rejects final_commission_amount below 0' do
      referral.final_commission_amount = -1
      expect(referral).not_to be_valid
    end

    it 'accepts nil final_commission_amount for non-closed_won states' do
      referral.status = 'pending'
      referral.final_commission_amount = nil
      expect(referral).to be_valid
    end

    describe 'closed_won requires final_commission_amount' do
      it 'is invalid when closed_won and amount is nil' do
        referral.status = 'closed_won'
        referral.final_commission_amount = nil
        expect(referral).not_to be_valid
        expect(referral.errors[:final_commission_amount]).to be_present
      end

      it 'is valid when closed_won and amount is present' do
        referral.status = 'closed_won'
        referral.final_commission_amount = 200_000
        expect(referral).to be_valid
      end

      it 'is invalid when closed_won and amount is exactly 0' do
        referral.status = 'closed_won'
        referral.final_commission_amount = 0
        expect(referral).not_to be_valid
        expect(referral.errors[:final_commission_amount]).to be_present
      end
    end
  end

  # -----------------------------------------------------------------------
  # Scopes
  # -----------------------------------------------------------------------
  describe 'scopes' do
    let!(:pending_ref)    { create(:referral, :pending) }
    let!(:forwarded_ref)  { create(:referral, :forwarded) }
    let!(:in_progress_ref) { create(:referral, :in_progress) }
    let!(:won_ref)        { create(:referral, :closed_won) }
    let!(:lost_ref)       { create(:referral, :closed_lost) }

    describe '.pending' do
      it 'returns only pending referrals' do
        expect(described_class.pending).to include(pending_ref)
        expect(described_class.pending).not_to include(forwarded_ref, won_ref)
      end
    end

    describe '.closed' do
      it 'returns closed_won and closed_lost' do
        expect(described_class.closed).to include(won_ref, lost_ref)
        expect(described_class.closed).not_to include(pending_ref, forwarded_ref)
      end
    end

    describe '.open' do
      it 'excludes closed_won and closed_lost' do
        expect(described_class.open).to include(pending_ref, forwarded_ref, in_progress_ref)
        expect(described_class.open).not_to include(won_ref, lost_ref)
      end
    end

    describe '.closed_won' do
      it 'returns only closed_won' do
        expect(described_class.closed_won).to include(won_ref)
        expect(described_class.closed_won).not_to include(lost_ref)
      end
    end

    describe '.for_agency' do
      let(:other_agency) { create(:partner_agency) }

      it 'filters by partner_agency instance' do
        expect(described_class.for_agency(pending_ref.partner_agency)).to include(pending_ref)
        expect(described_class.for_agency(other_agency)).not_to include(pending_ref)
      end

      it 'also accepts raw integer id' do
        expect(described_class.for_agency(pending_ref.partner_agency_id)).to include(pending_ref)
      end
    end

    describe '.awaiting_settlement' do
      it 'includes closed_won with no settled_at metadata' do
        expect(described_class.awaiting_settlement).to include(won_ref)
      end

      it 'excludes closed_lost' do
        expect(described_class.awaiting_settlement).not_to include(lost_ref)
      end
    end
  end

  # -----------------------------------------------------------------------
  # Soft delete
  # -----------------------------------------------------------------------
  describe 'soft delete' do
    let!(:referral) { create(:referral) }

    it 'sets deleted_at on destroy' do
      expect { referral.destroy }.to change { referral.reload.deleted_at }.from(nil)
    end

    it 'excludes destroyed referral from default scope' do
      referral.destroy
      expect(described_class.where(id: referral.id)).to be_empty
    end

    it 'remains accessible via unscoped' do
      referral.destroy
      expect(described_class.unscoped.where(id: referral.id)).to exist
    end
  end

  # -----------------------------------------------------------------------
  # State transition methods
  # -----------------------------------------------------------------------
  describe '#forward!' do
    let(:referral) { create(:referral, :pending) }

    it 'transitions to forwarded status' do
      referral.forward!(channel: 'email')
      expect(referral.reload.status).to eq('forwarded')
    end

    it 'sets forwarded_at timestamp' do
      referral.forward!(channel: 'email')
      expect(referral.reload.forwarded_at).to be_within(2.seconds).of(Time.current)
    end

    it 'stores forward_channel in metadata' do
      referral.forward!(channel: 'telegram')
      expect(referral.reload.metadata['forward_channel']).to eq('telegram')
    end

    it 'stores actor in metadata when provided' do
      referral.forward!(channel: 'email', actor: 'admin@agency.ru')
      expect(referral.reload.metadata['forwarded_by']).to eq('admin@agency.ru')
    end
  end

  describe '#close_won!' do
    let(:referral) { create(:referral, :in_progress) }

    it 'transitions to closed_won' do
      referral.close_won!(amount: 180_000)
      expect(referral.reload.status).to eq('closed_won')
    end

    it 'sets final_commission_amount' do
      referral.close_won!(amount: 180_000)
      expect(referral.reload.final_commission_amount).to eq(180_000)
    end

    it 'sets closed_at timestamp' do
      referral.close_won!(amount: 180_000)
      expect(referral.reload.closed_at).to be_within(2.seconds).of(Time.current)
    end
  end

  describe '#close_lost!' do
    let(:referral) { create(:referral, :forwarded) }

    it 'transitions to closed_lost' do
      referral.close_lost!(reason: 'Клиент не вышел на связь')
      expect(referral.reload.status).to eq('closed_lost')
    end

    it 'stores lost_reason in metadata' do
      referral.close_lost!(reason: 'Передумал')
      expect(referral.reload.metadata['lost_reason']).to eq('Передумал')
    end

    it 'sets closed_at timestamp' do
      referral.close_lost!(reason: 'nope')
      expect(referral.reload.closed_at).to be_within(2.seconds).of(Time.current)
    end
  end

  # -----------------------------------------------------------------------
  # Instance helper methods
  # -----------------------------------------------------------------------
  describe '#open? / #closed?' do
    it 'returns true from open? for non-closed statuses' do
      %w[pending forwarded in_progress stale].each do |s|
        expect(build(:referral, status: s).open?).to be(true), "expected open? for status=#{s}"
      end
    end

    it 'returns false from open? for CLOSED_STATUSES' do
      expect(build(:referral, :closed_won).open?).to be(false)
      expect(build(:referral, :closed_lost).open?).to be(false)
    end

    it 'returns true from closed? for CLOSED_STATUSES' do
      expect(build(:referral, :closed_won).closed?).to be(true)
      expect(build(:referral, :closed_lost).closed?).to be(true)
    end
  end

  describe '#estimated_commission' do
    context 'when final_commission_amount is present (closed_won)' do
      it 'returns final amount regardless of rate/listing' do
        referral = build(:referral, :closed_won, final_commission_amount: 95_000)
        expect(referral.estimated_commission).to eq(95_000.0)
      end
    end

    context 'when no final amount but rate and listing present' do
      it 'calculates price * rate' do
        listing = build(:external_listing, price: 5_000_000)
        referral = build(:referral, commission_rate: 0.30, external_listing: listing,
                                    final_commission_amount: nil)
        expect(referral.estimated_commission).to eq(1_500_000.0)
      end
    end

    context 'when commission_rate is blank' do
      it 'returns 0.0' do
        referral = build(:referral, commission_rate: nil, final_commission_amount: nil)
        expect(referral.estimated_commission).to eq(0.0)
      end
    end
  end
end
