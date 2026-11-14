# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::EscalationNotifier do
  let(:client) { instance_double(Telegram::Client) }

  describe 'тест-режим чат-бота (issue #214)' do
    let(:conv) { Conversation.create!(visitor_token: 'probe-maria-1211', status: :active) }

    around do |example|
      old = ENV.fetch('TELEGRAM_TEST_CHAT_ID', nil)
      ENV['TELEGRAM_TEST_CHAT_ID'] = '-100999888'
      example.run
      old.nil? ? ENV.delete('TELEGRAM_TEST_CHAT_ID') : ENV['TELEGRAM_TEST_CHAT_ID'] = old
    end

    it 'probe-диалог эскалирует в тестовый чат, а не в рабочий staff-chat' do
      expect(client).to receive(:send_message) do |text, kwargs|
        expect(kwargs[:chat_id]).to eq(-100_999_888)
        expect(text).to include('🧪 ТЕСТ')
        { 'message_id' => 42, 'chat' => { 'id' => -100_999_888 } }
      end

      described_class.new(conv, 'тестовая эскалация', client: client).call

      expect(conv.reload.telegram_chat_id).to eq(-100_999_888)
      expect(conv.telegram_message_id).to eq(42)
    end

    it 'без TELEGRAM_TEST_CHAT_ID эскалация пропускается (staff-chat не трогается)' do
      ENV.delete('TELEGRAM_TEST_CHAT_ID')
      expect(client).not_to receive(:send_message)

      expect(described_class.new(conv, 'тест', client: client).call).to be_nil
    end
  end

  describe 'боевой режим (регрессия)' do
    let(:conv) { Conversation.create!(visitor_token: 'aabbccddeeff00112233445566778899', status: :active) }

    it 'эскалирует в TELEGRAM_STAFF_CHAT_ID без ТЕСТ-маркера' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('TELEGRAM_STAFF_CHAT_ID').and_return('-1003937910508')

      expect(client).to receive(:send_message) do |text, kwargs|
        expect(kwargs[:chat_id]).to eq('-1003937910508') # боевой путь — исходная строка из ENV
        expect(text).not_to include('🧪 ТЕСТ')
        { 'message_id' => 77, 'chat' => { 'id' => -100_393_791_0508 } }
      end

      described_class.new(conv, 'боевая эскалация', client: client).call
    end

    it 'без TELEGRAM_STAFF_CHAT_ID сохраняется прежнее поведение — raise' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('TELEGRAM_STAFF_CHAT_ID').and_return(nil)

      expect { described_class.new(conv, 'боевая', client: client).call }
        .to raise_error(Telegram::Client::Error, /TELEGRAM_STAFF_CHAT_ID/)
    end
  end
end
