# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::LeadAnnouncer do
  let(:inquiry) { create(:inquiry, source: 'site_form') }
  let(:lead) do
    LeadEvent.create!(
      lead_ref:         inquiry,
      source:           'site_form',
      tg_chat_id:       -1_003_779_115_845,
      anchor_topic_key: 'dispatcher',
      current_stage:    'new',
      metadata:         { 'name' => 'Тест', 'phone' => '+790****4567', 'summary' => 'пробный прогон' }
    )
  end

  let(:client) { instance_double(Telegram::Client) }

  describe 'публикация тест-лида (issue #214)' do
    before { lead.update!(metadata: lead.metadata.merge('test' => true)) }

    around do |example|
      old = ENV.fetch('TELEGRAM_TEST_CHAT_ID', nil)
      ENV['TELEGRAM_TEST_CHAT_ID'] = '-100999888'
      example.run
      old.nil? ? ENV.delete('TELEGRAM_TEST_CHAT_ID') : ENV['TELEGRAM_TEST_CHAT_ID'] = old
    end

    it 'шлёт карточку в тестовый чат без message_thread_id — ДИСПЕТЧЕРСКАЯ не трогается' do
      expect(client).to receive(:send_message) do |text, kwargs|
        expect(kwargs[:chat_id]).to eq(-100_999_888)
        expect(kwargs).not_to have_key(:message_thread_id)
        { 'message_id' => 555 }
      end
      expect(described_class.new(lead, client: client).call).to be(true)
      expect(lead.reload.anchor_message_id).to eq(555)
    end

    it 'рендерит 🧪 ТЕСТ-бейдж в тексте карточки' do
      announcer = described_class.new(lead, client: client)
      expect(announcer.format_card_text).to include('🧪 <b>ТЕСТ</b>')
    end

    # Находка ревью PR #221: test-лид с auto-route (site_valuation → #ОЦЕНКА)
    # получал в anchor_thread_id рабочий топик 24, хотя опубликован в тестовом
    # чате без топика — anchor_url и следующие отправки уходили не туда.
    it 'test-лид с auto-route не получает рабочий anchor_thread_id' do
      lead = LeadEvent.create!(
        lead_ref:         inquiry,
        source:           'site_valuation',
        tg_chat_id:       -100_999_888,
        anchor_topic_key: 'dispatcher',
        current_stage:    'new',
        metadata:         { 'name' => 'Тест', 'test' => true }
      )
      expect(client).to receive(:send_message).and_return({ 'message_id' => 556 })

      expect(described_class.new(lead, client: client).call).to be(true)
      expect(lead.reload.anchor_thread_id).to be_nil
    end

    it 'без TELEGRAM_TEST_CHAT_ID публикация пропускается (send_message не дёргается)' do
      ENV.delete('TELEGRAM_TEST_CHAT_ID')
      expect(client).not_to receive(:send_message)
      expect(described_class.new(lead, client: client).call).to be(false)
    end
  end

  describe 'боевой лид (регрессия)' do
    it 'идёт в рабочий чат с message_thread_id топика и без ТЕСТ-бейджа' do
      allow(Telegram::TopicRegistry).to receive(:thread_id).and_return(4)
      expect(client).to receive(:send_message) do |text, kwargs|
        expect(kwargs[:chat_id]).to eq(-1_003_779_115_845)
        expect(kwargs[:message_thread_id]).to eq(4)
        { 'message_id' => 777 }
      end
      expect(described_class.new(lead, client: client).call).to be(true)
    end

    it 'не рендерит ТЕСТ-бейдж' do
      announcer = described_class.new(lead, client: client)
      expect(announcer.format_card_text).not_to include('ТЕСТ')
    end
  end
end
