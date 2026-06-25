# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DocumentRequirement do
  let(:buyer_order) do
    BuyerOrder.create!(crm_id: 900_902, client_name: 'Test', deal_type: 'sale',
                       deal_state: 'lead', synced_at: Time.current)
  end

  let(:lead) do
    LeadEvent.create!(
      lead_ref: buyer_order, source: 'site_form',
      tg_chat_id: -1_003_779_115_845, anchor_topic_key: 'apartments',
      current_stage: 'new'
    )
  end

  let(:tg_user) do
    TelegramUser.create!(tg_user_id: 9_001, status: 'active', role: 'agent')
  end

  def build_dr(attrs = {})
    described_class.new({
      lead_event: lead, kind: 'passport_main', status: 'not_requested'
    }.merge(attrs))
  end

  describe 'enums' do
    it 'document_kind has 16 values' do
      expect(described_class.kinds.size).to eq(16)
    end

    it 'status uses _prefix style' do
      dr = build_dr(status: 'received')
      expect(dr).to be_status_received
      expect(dr).not_to be_status_verified
    end

    it 'kind uses _prefix style' do
      expect(build_dr(kind: 'inn')).to be_kind_inn
    end
  end

  describe 'constants' do
    it 'SLA_SECONDS covers all 16 kinds' do
      expect(described_class::SLA_SECONDS.keys.sort).to eq(described_class.kinds.keys.sort)
    end

    it 'DEPENDS_ON contains contract_sale → [egrn_excerpt, passport_main]' do
      expect(described_class::DEPENDS_ON['contract_sale']).to contain_exactly('egrn_excerpt', 'passport_main')
    end

    it 'KIND_ALIASES maps RU + EN forms' do
      expect(described_class::KIND_ALIASES['ипотека']).to eq('mortgage_approval')
      expect(described_class::KIND_ALIASES['pass']).to eq('passport_main')
    end
  end

  describe 'soft delete' do
    let!(:dr) { build_dr.tap(&:save!) }

    it 'sets deleted_at on soft_destroy!' do
      expect { dr.soft_destroy! }.to change { dr.reload.deleted_at }.from(nil)
    end

    it 'excludes soft-deleted from default scope' do
      dr.soft_destroy!
      expect(described_class.where(id: dr.id)).to be_empty
      expect(described_class.unscoped.where(id: dr.id)).to exist
    end
  end

  describe 'lifecycle helpers' do
    let(:dr) { build_dr.tap(&:save!) }

    it '#request! sets status + actor + timestamp' do
      dr.request!(by: tg_user)
      expect(dr).to be_status_requested
      expect(dr.requested_by).to eq(tg_user)
      expect(dr.requested_at).to be_within(2.seconds).of(Time.current)
    end

    it '#receive! sets status + received_at' do
      dr.request!(by: tg_user)
      dr.receive!
      expect(dr).to be_status_received
      expect(dr.received_at).to be_present
    end

    it '#verify! sets status + verifier' do
      dr.update!(status: 'received', received_at: 1.hour.ago)
      dr.verify!(by: tg_user)
      expect(dr).to be_status_verified
      expect(dr.verified_by).to eq(tg_user)
    end

    it '#approve! sets status + approver' do
      dr.update!(status: 'verified', verified_at: 1.hour.ago)
      dr.approve!(by: tg_user)
      expect(dr).to be_status_approved
      expect(dr.approved_by).to eq(tg_user)
    end

    it '#reject! captures reason in metadata' do
      dr.reject!(by: tg_user, reason: 'не предоставлено')
      expect(dr).to be_status_rejected
      expect(dr.metadata['rejection_reason']).to eq('не предоставлено')
    end
  end

  describe 'SLA helpers' do
    it '#time_since_requested returns elapsed Float' do
      dr = build_dr(requested_at: 2.hours.ago).tap(&:save!)
      expect(dr.time_since_requested).to be_within(60).of(7_200)
    end

    it '#time_since_requested returns nil when not requested' do
      expect(build_dr(requested_at: nil).time_since_requested).to be_nil
    end

    it '#effective_sla uses SLA_SECONDS[kind] by default' do
      dr = build_dr(kind: 'passport_main')
      expect(dr.effective_sla).to eq(1.day.to_i)
    end

    it '#effective_sla uses overridden sla_seconds when set' do
      dr = build_dr(kind: 'passport_main', sla_seconds: 999)
      expect(dr.effective_sla).to eq(999)
    end

    it '#overdue_factor returns elapsed / sla' do
      dr = build_dr(kind: 'passport_main', requested_at: 2.days.ago).tap(&:save!)
      # SLA passport_main = 1d, elapsed ~2d → factor ~2.0
      expect(dr.overdue_factor).to be_within(0.1).of(2.0)
    end

    it '#overdue? = factor >= 1.0' do
      dr = build_dr(kind: 'passport_main', requested_at: 3.hours.ago).tap(&:save!)
      expect(dr.overdue?).to be(false)
    end
  end

  describe 'scopes' do
    let!(:not_req)  { build_dr(kind: 'passport_main', status: 'not_requested').tap(&:save!) }
    let!(:req)      { build_dr(kind: 'snils', status: 'requested', requested_at: 30.hours.ago).tap(&:save!) }
    let!(:received) { build_dr(kind: 'inn', status: 'received').tap(&:save!) }
    let!(:verified) { build_dr(kind: 'egrn_excerpt', status: 'verified').tap(&:save!) }

    it 'open includes not_requested / requested / received' do
      expect(described_class.open).to contain_exactly(not_req, req, received)
    end

    it 'overdue filters requested > 24h ago' do
      # req requested 30h ago > 24h → overdue
      expect(described_class.overdue).to include(req)
      expect(described_class.overdue).not_to include(not_req)
    end

    it 'final includes approved / rejected' do
      approved = build_dr(kind: 'contract_sale', status: 'approved').tap(&:save!)
      expect(described_class.final).to include(approved)
    end
  end

  describe 'unique constraint (lead_event_id, kind)' do
    it 'prevents duplicate non-deleted DR same kind on same lead' do
      build_dr(kind: 'passport_main').save!
      dup = build_dr(kind: 'passport_main')
      expect { dup.save! }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'allows recreate after soft-delete' do
      first = build_dr(kind: 'passport_main').tap(&:save!)
      first.soft_destroy!
      second = build_dr(kind: 'passport_main')
      expect { second.save! }.not_to raise_error
    end
  end

  describe '#ru_label' do
    it 'returns Russian label for known kinds' do
      expect(build_dr(kind: 'passport_main').ru_label).to eq('паспорт (основной)')
    end
  end
end
