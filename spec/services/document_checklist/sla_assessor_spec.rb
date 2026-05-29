# frozen_string_literal: true

require 'rails_helper'

# Phase 4F — pure-logic spec. Assessor НЕ имеет side-effects, ничего не
# persist'ит — testable полностью через synthetic DocumentRequirement
# instances. DR persistence нужен только для overdue_factor (использует
# Time.current внутри model) — поэтому build_dr возвращает saved record.
RSpec.describe DocumentChecklist::SlaAssessor do
  let(:buyer_order) do
    BuyerOrder.create!(client_name: 'Test', deal_type: 'sale',
                       deal_state: 'lead', synced_at: Time.current)
  end

  let(:lead) do
    LeadEvent.create!(lead_ref: buyer_order, source: 'site_form',
                      tg_chat_id: -1_003_779_115_845,
                      anchor_topic_key: 'apartments', current_stage: 'new')
  end

  def build_dr(kind: 'passport_main', status: 'requested', requested_at: nil,
               last_reminder_at: nil)
    DocumentRequirement.create!(
      lead_event: lead, kind: kind, status: status,
      requested_at: requested_at, last_reminder_at: last_reminder_at
    )
  end

  # Tuesday 12:00 MSK — guarantees not weekend
  let(:weekday_noon) { Time.zone.local(2026, 5, 19, 12, 0, 0) }
  let(:saturday_noon) { Time.zone.local(2026, 5, 16, 12, 0, 0) }

  describe 'constants' do
    it 'TIER_NAMES maps 1/2/3 → client_gentle/manager_dm/director_cascade' do
      expect(described_class::TIER_NAMES).to eq(
        1 => 'client_gentle', 2 => 'manager_dm', 3 => 'director_cascade'
      )
    end

    it 'TIER_OVERDUE_THRESHOLD increases monotonically' do
      th = described_class::TIER_OVERDUE_THRESHOLD
      expect(th[1]).to be < th[2]
      expect(th[2]).to be < th[3]
    end

    it 'TIER_REWINDOW has 24h/24h/48h cadence' do
      rw = described_class::TIER_REWINDOW
      expect(rw[1]).to eq(24.hours)
      expect(rw[2]).to eq(24.hours)
      expect(rw[3]).to eq(48.hours)
    end
  end

  describe '#assess — skip paths' do
    it 'skips final status verified' do
      dr = build_dr(status: 'verified')
      result = described_class.assess(dr, now: weekday_noon)
      expect(result.tier).to be_nil
      expect(result.reason).to include('final')
    end

    it 'skips final status approved' do
      dr = build_dr(status: 'approved')
      expect(described_class.assess(dr, now: weekday_noon).tier).to be_nil
    end

    it 'skips final status rejected' do
      dr = build_dr(status: 'rejected')
      expect(described_class.assess(dr, now: weekday_noon).tier).to be_nil
    end

    it 'skips when requested_at is nil' do
      dr = build_dr(status: 'requested', requested_at: nil)
      result = described_class.assess(dr, now: weekday_noon)
      expect(result.tier).to be_nil
      expect(result.reason).to include('not actionable')
    end

    it 'skips on weekend regardless of factor' do
      dr = build_dr(kind: 'passport_main', requested_at: saturday_noon - 10.days)
      result = described_class.assess(dr, now: saturday_noon)
      expect(result.tier).to be_nil
      expect(result.reason).to include('weekend')
    end
  end

  describe '#assess — tier classification' do
    it 'returns no tier when factor below 1.0' do
      # passport_main SLA = 1d. requested 12h ago → factor 0.5
      dr = build_dr(kind: 'passport_main', requested_at: weekday_noon - 12.hours)
      result = described_class.assess(dr, now: weekday_noon)
      expect(result.tier).to be_nil
    end

    it 'returns tier 1 (client_gentle) for 1.0 <= factor < 2.0' do
      # passport_main SLA = 1d. requested 36h ago → factor 1.5 → tier 1
      dr = build_dr(kind: 'passport_main', requested_at: weekday_noon - 36.hours)
      result = described_class.assess(dr, now: weekday_noon)
      expect(result.tier).to eq(1)
      expect(result.tier_name).to eq('client_gentle')
    end

    it 'returns tier 2 (manager_dm) for 2.0 <= factor < 3.0' do
      # inn SLA = 2d. requested 5d ago → factor 2.5 → tier 2
      dr = build_dr(kind: 'inn', requested_at: weekday_noon - 5.days)
      result = described_class.assess(dr, now: weekday_noon)
      expect(result.tier).to eq(2)
      expect(result.tier_name).to eq('manager_dm')
    end

    it 'returns tier 3 (director_cascade) when factor >= 3.0' do
      # egrn_excerpt SLA = 5d. requested 17.5d ago → factor 3.5 → tier 3
      dr = build_dr(kind: 'egrn_excerpt', requested_at: weekday_noon - 17.5.days)
      result = described_class.assess(dr, now: weekday_noon)
      expect(result.tier).to eq(3)
      expect(result.tier_name).to eq('director_cascade')
    end
  end

  describe '#assess — rewindow cooldown' do
    it 'skips tier 1 when last_reminder_at within 24h' do
      dr = build_dr(kind: 'passport_main',
                    requested_at: weekday_noon - 36.hours,
                    last_reminder_at: weekday_noon - 2.hours)
      result = described_class.assess(dr, now: weekday_noon)
      expect(result.tier).to be_nil
      expect(result.reason).to include('cooldown')
    end

    it 'allows tier 1 again after 24h+ elapsed' do
      dr = build_dr(kind: 'passport_main',
                    requested_at: weekday_noon - 36.hours,
                    last_reminder_at: weekday_noon - 25.hours)
      result = described_class.assess(dr, now: weekday_noon)
      expect(result.tier).to eq(1)
    end

    it 'tier 3 uses 48h rewindow (stricter)' do
      dr = build_dr(kind: 'egrn_excerpt',
                    requested_at: weekday_noon - 17.5.days,
                    last_reminder_at: weekday_noon - 30.hours)
      # 30h < 48h rewindow → cooldown skip
      result = described_class.assess(dr, now: weekday_noon)
      expect(result.tier).to be_nil
      expect(result.reason).to include('cooldown')
    end
  end

  describe 'Assessment struct' do
    it '#actionable? = true when tier present' do
      a = described_class::Assessment.new(tier: 1, tier_name: 'client_gentle')
      expect(a.actionable?).to be(true)
    end

    it '#actionable? = false when tier nil' do
      a = described_class::Assessment.new(tier: nil)
      expect(a.actionable?).to be(false)
    end
  end
end
