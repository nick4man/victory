# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::ShowRouting do
  let(:agent)    { TelegramUser.create!(tg_user_id: 111, role: 'agent', first_name: 'Ирина', status: 'active') }
  let!(:director) { TelegramUser.create!(tg_user_id: 333, role: 'director', first_name: 'Оксана', status: 'active') }

  def lead!(segment:)
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'tg_dm', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1, assigned_to: agent, segment: segment)
  end

  describe '.enabled?' do
    it 'выключен без переменной и включён только на строке true' do
      stub_const('ENV', ENV.to_h.except('SHOW_ROUTING_ENABLED'))
      expect(described_class.enabled?).to be(false)
      stub_const('ENV', ENV.to_h.merge('SHOW_ROUTING_ENABLED' => 'true'))
      expect(described_class.enabled?).to be(true)
    end
  end

  describe '.recommend' do
    it 'холодный → агент' do
      rec = described_class.recommend(lead!(segment: 'cold'))
      expect(rec.conductor).to eq(:agent)
      expect(rec.reason).to include('холодный')
    end

    it 'наличные / одобренная ипотека → руководитель' do
      expect(described_class.recommend(lead!(segment: 'cash')).conductor).to eq(:director)
      expect(described_class.recommend(lead!(segment: 'mortgage_approved')).conductor).to eq(:director)
    end

    it 'ипотека не одобрена / альтернатива → агент' do
      expect(described_class.recommend(lead!(segment: 'mortgage_pending')).conductor).to eq(:agent)
      expect(described_class.recommend(lead!(segment: 'alternative')).conductor).to eq(:agent)
    end

    it 'повторный показ → руководитель независимо от сегмента' do
      lead = lead!(segment: 'cold')
      ShowReport.create!(lead_event: lead, conducted_by: agent, reported_by: agent, conducted_at: 1.day.ago,
                         source: 'voice', status: 'confirmed')
      rec = described_class.recommend(lead)
      expect(rec.conductor).to eq(:director)
      expect(rec.reason).to include('повторный')
    end

    it 'сегмент не указан → unknown' do
      expect(described_class.recommend(lead!(segment: nil)).conductor).to eq(:unknown)
    end
  end

  describe '.keyboard' do
    it 'кнопка на assignee и на каждого активного директора, ≤64 байт' do
      lead = lead!(segment: 'cold')
      buttons = described_class.keyboard(lead)[:inline_keyboard].flatten
      expect(buttons.map { |b| b[:callback_data] }).to contain_exactly("show_assign:#{lead.id}:#{agent.id}",
                                                                      "show_assign:#{lead.id}:#{director.id}")
      buttons.each { |b| expect(b[:callback_data].bytesize).to be <= 64 }
    end
  end
end
