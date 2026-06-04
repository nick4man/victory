# frozen_string_literal: true

require 'rails_helper'

# Phase 4C — Auto-instantiate DocumentRequirement checklist.
# Critical invariants под охраной этого spec:
#   • Template resolution (property_type × deal_type, inquiry_type fallback,
#     default_sale ultimate fallback)
#   • DEPENDS_ON cascade (создание contract_sale → ensures egrn + passport)
#   • Idempotency (re-run = skip existing через unique constraint)
#   • Optional condition lambdas (married/has_proxy/has_mortgage)
RSpec.describe DocumentChecklist::Builder do
  let(:tg_user) do
    TelegramUser.create!(tg_user_id: 6_001, status: 'active', role: 'manager')
  end

  def build_lead(lead_ref:, metadata: { 'name' => 'Test' })
    LeadEvent.create!(
      lead_ref: lead_ref, source: 'site_form',
      tg_chat_id: -1_003_779_115_845, anchor_topic_key: 'apartments',
      current_stage: 'new', metadata: metadata
    )
  end

  describe 'template resolution' do
    context 'when lead.lead_ref is nil' do
      let(:buyer_order) do
        BuyerOrder.create!(crm_id: 900_903, client_name: 'Test', deal_type: 'sale',
                           deal_state: 'lead', synced_at: Time.current)
      end
      let(:lead) { build_lead(lead_ref: buyer_order) }

      before { lead.update_columns(lead_ref_type: nil, lead_ref_id: nil) }

      it 'falls back to default_sale' do
        result = described_class.new(lead_event: lead, actor: tg_user).call
        expect(result.template_key).to eq('default_sale')
        expect(result.success?).to be(true)
      end
    end

    context 'when lead.lead_ref is Inquiry with mortgage type' do
      let(:inquiry) do
        Inquiry.create!(inquiry_type: 'mortgage', name: 'Mort User',
                        phone: '+79991234567', message: 'ипотека',
                        source: 'site_mortgage', status: 'new')
      end
      let(:lead) { build_lead(lead_ref: inquiry) }

      it 'resolves to mortgage template' do
        result = described_class.new(lead_event: lead, actor: tg_user).call
        expect(result.template_key).to eq('mortgage')
      end

      it 'creates mortgage_approval as part of required set' do
        result = described_class.new(lead_event: lead, actor: tg_user).call
        kinds = result.created.map(&:kind)
        expect(kinds).to include('mortgage_approval')
      end
    end

    context 'when lead.lead_ref is Inquiry with evaluation type' do
      let(:inquiry) do
        Inquiry.create!(inquiry_type: 'evaluation', name: 'Eval User',
                        phone: '+79991234567', message: 'оценка',
                        source: 'site_valuation', status: 'new')
      end
      let(:lead) { build_lead(lead_ref: inquiry) }

      it 'resolves to evaluation template' do
        result = described_class.new(lead_event: lead, actor: tg_user).call
        expect(result.template_key).to eq('evaluation')
      end

      it 'includes appraisal_report' do
        result = described_class.new(lead_event: lead, actor: tg_user).call
        expect(result.created.map(&:kind)).to include('appraisal_report')
      end
    end
  end

  describe 'DEPENDS_ON cascade' do
    let(:inquiry) do
      Inquiry.create!(inquiry_type: 'quick_inquiry', name: 'Cascade Test',
                      phone: '+79991234567', message: 'test',
                      source: 'site_form', status: 'new')
    end
    let(:lead) { build_lead(lead_ref: inquiry) }

    it 'default_sale creates contract_sale → cascades to egrn_excerpt + passport_main' do
      result = described_class.new(lead_event: lead, actor: tg_user).call
      kinds = result.created.map(&:kind)
      # default_sale required: passport_main, egrn_excerpt, contract_sale
      # contract_sale triggers DEPENDS_ON → egrn_excerpt + passport_main
      # уже в required → cascade skip duplicate (unique constraint)
      expect(kinds).to include('passport_main', 'egrn_excerpt', 'contract_sale')
    end

    it 'cascade-duplicates appear in skipped (not created twice)' do
      result = described_class.new(lead_event: lead, actor: tg_user).call
      # passport_main + egrn cascade skip — already in required template
      expect(result.skipped.size).to be >= 1
    end
  end

  describe 'idempotency' do
    let(:inquiry) do
      Inquiry.create!(inquiry_type: 'quick_inquiry', name: 'Idem',
                      phone: '+79991234567', message: 'test',
                      source: 'site_form', status: 'new')
    end
    let(:lead) { build_lead(lead_ref: inquiry) }

    it 're-running creates 0 new, skips all' do
      first = described_class.new(lead_event: lead, actor: tg_user).call
      second = described_class.new(lead_event: lead, actor: tg_user).call

      expect(first.created).not_to be_empty
      expect(second.created).to be_empty
      expect(second.skipped.size).to eq(first.created.size)
    end

    it 'savepoint transactions allow continuing after unique violation' do
      described_class.new(lead_event: lead, actor: tg_user).call
      # Should not raise RecordNotUnique despite all conflicts
      expect do
        described_class.new(lead_event: lead, actor: tg_user).call
      end.not_to raise_error
    end
  end

  describe 'optional conditions' do
    let(:inquiry) do
      Inquiry.create!(inquiry_type: 'mortgage', name: 'Optional Test',
                      phone: '+79991234567', message: 'test',
                      source: 'site_mortgage', status: 'new')
    end

    it 'married=true triggers spousal_consent в mortgage template' do
      lead = build_lead(lead_ref: inquiry, metadata: { 'name' => 'X', 'client_marital_status' => 'married' })
      result = described_class.new(lead_event: lead, actor: tg_user).call
      expect(result.created.map(&:kind)).to include('spousal_consent')
    end

    it 'married=false does NOT trigger spousal_consent' do
      lead = build_lead(lead_ref: inquiry, metadata: { 'name' => 'X', 'client_marital_status' => 'single' })
      result = described_class.new(lead_event: lead, actor: tg_user).call
      expect(result.created.map(&:kind)).not_to include('spousal_consent')
    end
  end

  describe 'Result struct' do
    it 'returns Result with all fields populated on success' do
      inquiry = Inquiry.create!(inquiry_type: 'quick_inquiry', name: 'R',
                                phone: '+79991234567', message: 'r',
                                source: 'site_form', status: 'new')
      lead = build_lead(lead_ref: inquiry)
      result = described_class.new(lead_event: lead, actor: tg_user).call

      expect(result).to be_success
      expect(result.created).to be_an(Array)
      expect(result.skipped).to be_an(Array)
      expect(result.template_key).to be_a(String)
      expect(result.error).to be_nil
    end
  end
end
