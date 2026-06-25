# frozen_string_literal: true

require 'rails_helper'

# Phase 4G — auto-match A6 ClientDocument → DocumentRequirement. Critical
# logic под охраной spec:
#   • KIND_MAP (4 mappings) — passport/inn/egrn/contract → DR kinds
#   • Confidence threshold routing (>= 0.7 auto-link / < 0.7 flagged)
#   • Lead resolution (inquiry_id → LeadEvent OR property_id → recent Inquiry)
#   • Idempotency (with_lock + reload prevents override verified/approved)
#
# TG client заменяется на stub (мы тестируем match logic, не messaging).
RSpec.describe DocumentChecklist::AutoMatchToRequirement do
  before do
    # Stub TG client globally — message dispatch не должен влиять на match logic
    allow_any_instance_of(Telegram::Client).to receive(:send_message).and_return({ 'message_id' => 1 })
  end

  let(:user) do
    User.create!(email: "auto-#{SecureRandom.hex(4)}@victory.test",
                 first_name: 'Auto', last_name: 'Agent',
                 password: 'TestPass123!', password_confirmation: 'TestPass123!')
  end

  let(:tg_user) do
    TelegramUser.create!(tg_user_id: 7_001, status: 'active', role: 'agent')
  end

  let(:inquiry) do
    Inquiry.create!(inquiry_type: 'quick_inquiry', name: 'AutoMatch Test',
                    phone: '+79991234567', message: 'test',
                    source: 'site_form', status: 'new')
  end

  let(:lead) do
    le = LeadEvent.create!(
      lead_ref: inquiry, source: 'site_form',
      tg_chat_id: -1_003_779_115_845, anchor_topic_key: 'apartments',
      current_stage: 'new'
    )
    le.update!(assigned_to: tg_user)
    le
  end

  def build_client_document(kind: 'passport', confidence: 0.9, inquiry_id: inquiry.id)
    cd = ClientDocument.new(
      uploader_id: user.id,
      inquiry_id: inquiry_id,
      document_kind: kind,
      status: 'ocr_completed',
      parsed_data: { 'confidence' => confidence },
      tg_file_id: "fake-#{SecureRandom.hex(4)}"
    )
    cd.save!(validate: false) # avoid Devise/legacy validations
    cd
  end

  describe 'KIND_MAP' do
    it 'maps passport → passport_main' do
      expect(described_class::KIND_MAP['passport']).to eq('passport_main')
    end

    it 'maps egrn → egrn_excerpt' do
      expect(described_class::KIND_MAP['egrn']).to eq('egrn_excerpt')
    end

    it 'maps contract → contract_sale' do
      expect(described_class::KIND_MAP['contract']).to eq('contract_sale')
    end

    it 'does NOT map "other"' do
      expect(described_class::KIND_MAP['other']).to be_nil
    end
  end

  describe '#call — skip paths' do
    it 'skips document_kind=other' do
      doc = build_client_document(kind: 'other')
      result = described_class.call(client_document: doc)
      expect(result.status).to eq(:skipped)
      expect(result.reason).to include('no DR kind mapping')
    end

    it 'skips when ClientDocument has no inquiry_id/property_id' do
      doc = ClientDocument.new(uploader_id: user.id, document_kind: 'passport',
                               status: 'ocr_completed',
                               parsed_data: { 'confidence' => 0.9 },
                               tg_file_id: 'orphan')
      doc.save!(validate: false)
      result = described_class.call(client_document: doc)
      expect(result.status).to eq(:skipped)
      expect(result.reason).to include('no associated LeadEvent')
    end

    it 'skips when no open DR of matching kind exists' do
      lead # touch to ensure LeadEvent exists, but NO DR created
      doc = build_client_document(kind: 'passport')
      result = described_class.call(client_document: doc)
      expect(result.status).to eq(:skipped)
      expect(result.reason).to include('no open DR')
    end

    it 'skips when only verified DRs exist (does NOT override human review)' do
      lead
      DocumentRequirement.create!(lead_event: lead, kind: 'passport_main',
                                  status: 'verified', requested_at: 2.days.ago,
                                  verified_at: 1.hour.ago)
      doc = build_client_document(kind: 'passport')
      result = described_class.call(client_document: doc)
      expect(result.status).to eq(:skipped)
    end
  end

  describe '#call — high confidence (>= 0.7) auto-link' do
    let!(:dr) do
      DocumentRequirement.create!(lead_event: lead, kind: 'passport_main',
                                  status: 'requested', requested_at: 1.day.ago)
    end

    it 'returns :auto_linked with matched requirement' do
      doc = build_client_document(kind: 'passport', confidence: 0.95)
      result = described_class.call(client_document: doc)
      expect(result.status).to eq(:auto_linked)
      expect(result.requirement.id).to eq(dr.id)
    end

    it 'updates DR.status → received' do
      doc = build_client_document(kind: 'passport', confidence: 0.95)
      described_class.call(client_document: doc)
      expect(dr.reload.status).to eq('received')
    end

    it 'sets received_via_client_document_id' do
      doc = build_client_document(kind: 'passport', confidence: 0.95)
      described_class.call(client_document: doc)
      expect(dr.reload.received_via_client_document_id).to eq(doc.id)
    end

    it 'enriches metadata.auto_matched=true с confidence' do
      doc = build_client_document(kind: 'passport', confidence: 0.85)
      described_class.call(client_document: doc)
      meta = dr.reload.metadata
      expect(meta['auto_matched']).to be(true)
      expect(meta['auto_match_confidence']).to be_within(0.001).of(0.85)
    end
  end

  describe '#call — low confidence (< 0.7) flagged for review' do
    let!(:dr) do
      DocumentRequirement.create!(lead_event: lead, kind: 'inn',
                                  status: 'requested', requested_at: 1.day.ago)
    end

    it 'returns :flagged_for_review' do
      doc = build_client_document(kind: 'inn', confidence: 0.45)
      result = described_class.call(client_document: doc)
      expect(result.status).to eq(:flagged_for_review)
      expect(result.reason).to include('0.45')
    end

    it 'DOES NOT update DR.status' do
      doc = build_client_document(kind: 'inn', confidence: 0.5)
      described_class.call(client_document: doc)
      expect(dr.reload.status).to eq('requested')
    end

    it 'edge case: confidence exactly at threshold (0.7) → auto-link' do
      doc = build_client_document(kind: 'inn', confidence: 0.7)
      result = described_class.call(client_document: doc)
      expect(result.status).to eq(:auto_linked)
    end

    it 'edge case: just below threshold (0.69) → flagged' do
      doc = build_client_document(kind: 'inn', confidence: 0.69)
      result = described_class.call(client_document: doc)
      expect(result.status).to eq(:flagged_for_review)
    end
  end

  describe 'Result struct' do
    it '#success? = true для :auto_linked only' do
      result = described_class::Result.new(status: :auto_linked)
      expect(result.success?).to be(true)
    end

    it '#success? = false для :skipped' do
      result = described_class::Result.new(status: :skipped)
      expect(result.success?).to be(false)
    end

    it '#success? = false для :flagged_for_review' do
      result = described_class::Result.new(status: :flagged_for_review)
      expect(result.success?).to be(false)
    end
  end
end
