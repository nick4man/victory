# frozen_string_literal: true

require 'rails_helper'

# Phase 4B — Manager composes Tokenizer parse output → applies lifecycle
# transitions через DR helpers (request!/receive!/verify!/approve!/reject!).
# Plus format_status returns HTML view grouped by state.
RSpec.describe DocumentChecklist::Manager do
  let(:tg_user) do
    TelegramUser.create!(tg_user_id: 9_101, status: 'active', role: 'manager',
                         first_name: 'Mgr', tg_username: 'mgr')
  end

  let(:inquiry) do
    Inquiry.create!(inquiry_type: 'quick_inquiry', name: 'Mgr Test',
                    phone: '+79991234567', message: 'test',
                    source: 'site_form', status: 'new')
  end

  let(:lead) do
    LeadEvent.create!(lead_ref: inquiry, source: 'site_form',
                      tg_chat_id: -1_003_779_115_845,
                      anchor_topic_key: 'apartments', current_stage: 'new',
                      metadata: { 'name' => 'Mgr Test' })
  end

  describe '#apply — single-token lifecycle' do
    it 'creates new DR + transitions to received on passport+' do
      tokens = [{ kind: 'passport_main', action: :received }]
      result = described_class.new(lead_event: lead, actor: tg_user).apply(tokens)

      expect(result).to be_success
      expect(result.records.size).to eq(1)
      dr = result.records.first
      expect(dr).to be_status_received
      expect(dr.received_at).to be_present
    end

    it 'requests via ? action sets requested_by + requested_at' do
      tokens = [{ kind: 'snils', action: :requested }]
      described_class.new(lead_event: lead, actor: tg_user).apply(tokens)

      dr = DocumentRequirement.find_by(lead_event_id: lead.id, kind: 'snils')
      expect(dr).to be_status_requested
      expect(dr.requested_by).to eq(tg_user)
      expect(dr.requested_at).to be_within(2.seconds).of(Time.current)
    end

    it 'reverts to not_requested on minus action' do
      DocumentRequirement.create!(lead_event: lead, kind: 'inn',
                                  status: 'requested', requested_at: 1.day.ago,
                                  requested_by: tg_user)
      tokens = [{ kind: 'inn', action: :not_requested }]
      described_class.new(lead_event: lead, actor: tg_user).apply(tokens)

      dr = DocumentRequirement.find_by(lead_event_id: lead.id, kind: 'inn')
      expect(dr).to be_status_not_requested
      expect(dr.requested_at).to be_nil
      expect(dr.received_at).to be_nil
    end

    it 'admin-leap = approved goes through received → verified → approved' do
      tokens = [{ kind: 'contract_sale', action: :approved }]
      described_class.new(lead_event: lead, actor: tg_user).apply(tokens)

      dr = DocumentRequirement.find_by(lead_event_id: lead.id, kind: 'contract_sale')
      expect(dr).to be_status_approved
      expect(dr.approved_by).to eq(tg_user)
    end
  end

  describe '#apply — combined leap (+verified)' do
    it 'received + immediately verified on same token' do
      tokens = [{ kind: 'passport_main', action: :received, also: :verified }]
      described_class.new(lead_event: lead, actor: tg_user).apply(tokens)

      dr = DocumentRequirement.find_by(lead_event_id: lead.id, kind: 'passport_main')
      expect(dr).to be_status_verified
      expect(dr.verified_by).to eq(tg_user)
    end
  end

  describe '#apply — rejection с reason' do
    it 'sets status=rejected + reason in metadata' do
      tokens = [{ kind: 'power_of_attorney', action: :rejected, reason: 'no_notary' }]
      described_class.new(lead_event: lead, actor: tg_user).apply(tokens)

      dr = DocumentRequirement.find_by(lead_event_id: lead.id, kind: 'power_of_attorney')
      expect(dr).to be_status_rejected
      expect(dr.metadata['rejection_reason']).to eq('no_notary')
    end
  end

  describe '#apply — batch' do
    it 'processes multiple tokens in single transaction' do
      tokens = [
        { kind: 'passport_main', action: :received },
        { kind: 'snils', action: :requested },
        { kind: 'inn', action: :requested }
      ]
      result = described_class.new(lead_event: lead, actor: tg_user).apply(tokens)

      expect(result).to be_success
      expect(result.records.size).to eq(3)
      kinds = result.records.map(&:kind).sort
      expect(kinds).to eq(%w[inn passport_main snils])
    end

    it 'rolls back ALL on apply error (atomic)' do
      # Force an error путём передачи nil action
      tokens = [
        { kind: 'passport_main', action: :received },
        { kind: 'snils', action: :unknown_action } # raises ApplyError
      ]
      result = described_class.new(lead_event: lead, actor: tg_user).apply(tokens)

      expect(result).not_to be_success
      # No records should have been created (rollback)
      expect(DocumentRequirement.where(lead_event_id: lead.id)).to be_empty
    end
  end

  describe '#apply — empty input' do
    it 'returns success=false with message' do
      result = described_class.new(lead_event: lead, actor: tg_user).apply([])
      expect(result).not_to be_success
      expect(result.message).to include('Пустой')
    end
  end

  describe '#format_status' do
    it 'returns init hint when no requirements exist' do
      text = described_class.new(lead_event: lead, actor: tg_user).format_status
      expect(text).to include('Чек-лист пуст')
      expect(text).to include('/doc init')
    end

    it 'shows ✅ ГОТОВЫ section for verified/approved' do
      DocumentRequirement.create!(lead_event: lead, kind: 'passport_main',
                                  status: 'verified', received_at: 1.hour.ago,
                                  verified_at: 30.minutes.ago, verified_by: tg_user)
      text = described_class.new(lead_event: lead, actor: tg_user).format_status
      expect(text).to include('ГОТОВЫ')
      expect(text).to include('паспорт (основной)')
    end

    it 'shows ⏳ ЗАПРОШЕНЫ with SLA suffix' do
      DocumentRequirement.create!(lead_event: lead, kind: 'snils',
                                  status: 'requested', requested_at: 1.hour.ago)
      text = described_class.new(lead_event: lead, actor: tg_user).format_status
      expect(text).to include('ЗАПРОШЕНЫ')
    end

    it 'shows progress percentage' do
      DocumentRequirement.create!(lead_event: lead, kind: 'passport_main',
                                  status: 'verified', verified_at: 1.hour.ago)
      DocumentRequirement.create!(lead_event: lead, kind: 'snils', status: 'requested',
                                  requested_at: 1.hour.ago)
      text = described_class.new(lead_event: lead, actor: tg_user).format_status
      # 1 verified из 2 → 50%
      expect(text).to include('1/2')
      expect(text).to include('(50%)')
    end
  end

  describe 'idempotency' do
    it 're-applying same received action does not error' do
      tokens = [{ kind: 'passport_main', action: :received }]
      described_class.new(lead_event: lead, actor: tg_user).apply(tokens)
      result = described_class.new(lead_event: lead, actor: tg_user).apply(tokens)
      expect(result).to be_success
    end
  end
end
