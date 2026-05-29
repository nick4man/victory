# frozen_string_literal: true

require 'rails_helper'

# Phase 4F — Per-tier reminder DM dispatch. Heavy на TG stubs — мы тестируем
# WHICH recipients are targeted per-tier + что happens с DR.last_reminder_at/
# reminder_count after send, NOT actual TG content.
RSpec.describe DocumentChecklist::ReminderSender do
  let(:tg_stub) { instance_double(Telegram::Client) }

  before do
    allow(tg_stub).to receive(:send_message).and_return({ 'message_id' => 1 })
    # AlertThrottle stub — return true by default (allow first send)
    allow(Telegram::AlertThrottle).to receive(:allow?).and_return(true)
  end

  let(:assignee) do
    TelegramUser.create!(tg_user_id: 10_001, status: 'active', role: 'agent',
                         first_name: 'Иван', tg_username: 'ivan_agent',
                         dm_chat_id: 10_001)
  end

  let(:inquiry) do
    Inquiry.create!(
      inquiry_type: 'quick_inquiry', name: 'Reminder Test',
      phone: nil, message: 'test', source: 'tg_dm', status: 'new',
      client_tg_user_id: 555_111
    )
  end

  let(:lead) do
    LeadEvent.create!(lead_ref: inquiry, source: 'tg_dm',
                      tg_chat_id: -1_003_779_115_845,
                      anchor_topic_key: 'apartments', current_stage: 'new',
                      assigned_to: assignee, assigned_at: 1.hour.ago,
                      metadata: { 'name' => 'Reminder Test' })
  end

  let(:dr) do
    DocumentRequirement.create!(lead_event: lead, kind: 'passport_main',
                                status: 'requested', requested_at: 36.hours.ago)
  end

  describe '#call — Tier 1 (client_gentle)' do
    it 'sends DM to client_tg_user_id (= dm_chat_id для private TG)' do
      expect(tg_stub).to receive(:send_message).with(
        anything, hash_including(chat_id: 555_111, parse_mode: 'HTML')
      ).and_return({ 'message_id' => 1 })

      result = described_class.new(requirement: dr, tier: 1, tg_client: tg_stub).call
      expect(result).to be_success
      expect(result.tier).to eq(1)
      expect(result.recipients_count).to eq(1)
    end

    it 'returns 0 recipients when inquiry lacks client_tg_user_id' do
      inquiry.update!(client_tg_user_id: nil)
      result = described_class.new(requirement: dr, tier: 1, tg_client: tg_stub).call
      expect(result.recipients_count).to eq(0)
      expect(result.sent).to be(false)
    end
  end

  describe '#call — Tier 2 (manager_dm)' do
    it 'sends DM to assignee dm_chat_id' do
      expect(tg_stub).to receive(:send_message).with(
        anything, hash_including(chat_id: assignee.dm_chat_id)
      ).and_return({ 'message_id' => 1 })

      result = described_class.new(requirement: dr, tier: 2, tg_client: tg_stub).call
      expect(result).to be_success
      expect(result.recipients_count).to eq(1)
    end

    it 'returns 0 when no assignee on lead' do
      lead.update!(assigned_to: nil)
      result = described_class.new(requirement: dr, tier: 2, tg_client: tg_stub).call
      expect(result.recipients_count).to eq(0)
    end
  end

  describe '#call — Tier 3 (director_cascade)' do
    let!(:director) do
      TelegramUser.create!(tg_user_id: 10_002, status: 'active', role: 'director',
                           dm_chat_id: 10_002)
    end

    it 'uses CriticalRecipients cascade (director first if available)' do
      result = described_class.new(requirement: dr, tier: 3, tg_client: tg_stub).call
      expect(result).to be_success
      expect(result.recipients_count).to be >= 1
    end
  end

  describe '#call — throttle' do
    it 'returns sent=false когда AlertThrottle отклоняет' do
      allow(Telegram::AlertThrottle).to receive(:allow?).and_return(false)
      result = described_class.new(requirement: dr, tier: 1, tg_client: tg_stub).call
      expect(result.sent).to be(false)
      expect(result.error).to eq('throttled')
    end

    it 'throttle key includes lead_id + dr_id + tier для uniqueness' do
      expected_key = "doc_reminder:#{lead.id}:#{dr.id}:tier1"
      expect(Telegram::AlertThrottle).to receive(:allow?).with(key: expected_key).and_return(true)
      described_class.new(requirement: dr, tier: 1, tg_client: tg_stub).call
    end
  end

  describe '#call — mark_sent! side-effects' do
    it 'increments reminder_count + sets last_reminder_at after successful send' do
      expect { described_class.new(requirement: dr, tier: 1, tg_client: tg_stub).call }
        .to change { dr.reload.reminder_count }.by(1)
        .and change { dr.reload.last_reminder_at }.from(nil)
    end

    it 'enriches metadata.last_reminder_tier' do
      described_class.new(requirement: dr, tier: 2, tg_client: tg_stub).call
      expect(dr.reload.metadata['last_reminder_tier']).to eq(2)
    end

    it 'does NOT mark_sent! when recipients_count = 0' do
      inquiry.update!(client_tg_user_id: nil)
      described_class.new(requirement: dr, tier: 1, tg_client: tg_stub).call
      expect(dr.reload.reminder_count).to eq(0)
      expect(dr.reload.last_reminder_at).to be_nil
    end
  end

  describe 'Result struct' do
    it '#success? = true когда sent + no error' do
      r = described_class::Result.new(sent: true, tier: 1, recipients_count: 1, error: nil)
      expect(r.success?).to be(true)
    end

    it '#success? = false когда throttled' do
      r = described_class::Result.new(sent: false, tier: 1, recipients_count: 0, error: 'throttled')
      expect(r.success?).to be(false)
    end
  end
end
