# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AuditReportNotifier do
  let(:client) { instance_double(Telegram::Client) }
  let(:valuation) { PropertyValuation.new(metadata: metadata) }
  let(:metadata) { {} }

  before do
    allow(Telegram::Client).to receive(:new).and_return(client)
    allow(AuditPdfGenerator).to receive(:call).and_return('%PDF-1.4 test')
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('TELEGRAM_BOT_TOKEN').and_return('test-token')
  end

  describe 'тест-режим чат-бота (issue #214)' do
    let(:metadata) { { 'test' => true } }

    around do |example|
      old = ENV.fetch('TELEGRAM_TEST_CHAT_ID', nil)
      ENV['TELEGRAM_TEST_CHAT_ID'] = '-100999888'
      example.run
      old.nil? ? ENV.delete('TELEGRAM_TEST_CHAT_ID') : ENV['TELEGRAM_TEST_CHAT_ID'] = old
    end

    it 'тестовый аудит уходит в TELEGRAM_TEST_CHAT_ID, а не в рабочие audits/staff' do
      expect(client).to receive(:send_message) do |_text, kwargs|
        expect(kwargs[:chat_id]).to eq('-100999888')
        { 'message_id' => 1 }
      end
      expect(client).to receive(:send_document) do |_doc, kwargs|
        expect(kwargs[:chat_id]).to eq('-100999888')
        { 'message_id' => 2 }
      end

      expect(described_class.notify(valuation)).to be(true)
    end

    it 'без TELEGRAM_TEST_CHAT_ID — пропуск, рабочие чаты не трогаются' do
      ENV.delete('TELEGRAM_TEST_CHAT_ID')
      expect(client).not_to receive(:send_message)

      expect(described_class.notify(valuation)).to be(false)
    end
  end

  describe 'боевой режим (регрессия)' do
    it 'идёт в TELEGRAM_AUDITS_CHAT_ID по-прежнему' do
      allow(ENV).to receive(:[]).with('TELEGRAM_AUDITS_CHAT_ID').and_return('-100500')
      allow(ENV).to receive(:[]).with('TELEGRAM_STAFF_CHAT_ID').and_return('-1003937910508')

      expect(client).to receive(:send_message) do |_text, kwargs|
        expect(kwargs[:chat_id]).to eq('-100500')
        { 'message_id' => 1 }
      end
      expect(client).to receive(:send_document).and_return({ 'message_id' => 2 })

      expect(described_class.notify(valuation)).to be(true)
    end
  end
end
