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

  # Issue #227 (rev #230, round 3): staff_test по сильному правилу детектора —
  # та же изоляция, что у metadata['test']; слабое name_staff_first боевой
  # маршрут не меняет (иначе реальный клиент «Надежда» остался бы без отчёта).
  describe 'staff_test-изоляция (issue #227)' do
    let(:valuation) do
      Thread.current[:skip_workbot_push] = true
      PropertyValuation.create!(staff_test: true, staff_test_matched_by: 'email_staff_match',
                                property_type: 'apartment', deal_type: 'sale', status: 'completed',
                                address: 'г. Рязань, тестовый адрес 1', total_area: 44.0,
                                latitude: 54.6292, longitude: 39.7417,
                                estimated_price: 4_000_000)
    ensure
      Thread.current[:skip_workbot_push] = nil
    end

    around do |example|
      old = ENV.fetch('TELEGRAM_TEST_CHAT_ID', nil)
      ENV['TELEGRAM_TEST_CHAT_ID'] = '-100999888'
      example.run
      old.nil? ? ENV.delete('TELEGRAM_TEST_CHAT_ID') : ENV['TELEGRAM_TEST_CHAT_ID'] = old
    end

    it 'сильное правило → аудит в тестовый чат, маркер «🧪 ТЕСТ»' do
      expect(client).to receive(:send_message) do |text, kwargs|
        expect(kwargs[:chat_id]).to eq('-100999888')
        expect(text).to include('🧪 ТЕСТ')
        { 'message_id' => 1 }
      end
      expect(client).to receive(:send_document) do |_doc, kwargs|
        expect(kwargs[:chat_id]).to eq('-100999888')
        expect(kwargs[:caption]).to include('ТЕСТ')
        { 'message_id' => 2 }
      end

      expect(described_class.notify(valuation)).to be(true)
    end

    it 'слабое правило name_staff_first → боевой маршрут (рабочая группа)' do
      valuation.update_columns(staff_test_matched_by: 'name_staff_first')
      allow(ENV).to receive(:[]).with('TELEGRAM_AUDITS_CHAT_ID').and_return('-100500')

      expect(client).to receive(:send_message) do |_text, kwargs|
        expect(kwargs[:chat_id]).to eq('-100500')
        { 'message_id' => 1 }
      end
      expect(client).to receive(:send_document).and_return({ 'message_id' => 2 })

      expect(described_class.notify(valuation)).to be(true)
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

  # Issue #224 (ревью PR #221, round 5, нит): маркер «🧪 ТЕСТ» без склейки
  # слов — caption «🧪 ТЕСТ · PDF-отчёт …», заголовок summary «… · 🧪 ТЕСТ».
  describe 'маркер test? (round 5)' do
    let(:metadata) { { 'test' => true } }

    around do |example|
      old = ENV.fetch('TELEGRAM_TEST_CHAT_ID', nil)
      ENV['TELEGRAM_TEST_CHAT_ID'] = '-100999888'
      example.run
      old.nil? ? ENV.delete('TELEGRAM_TEST_CHAT_ID') : ENV['TELEGRAM_TEST_CHAT_ID'] = old
    end

    it 'caption PDF: «🧪 ТЕСТ · PDF-отчёт …»' do
      expect(client).to receive(:send_message).and_return({ 'message_id' => 1 })
      expect(client).to receive(:send_document) do |_doc, kwargs|
        expect(kwargs[:caption]).to start_with("🧪 ТЕСТ · PDF-отчёт ")
        { 'message_id' => 2 }
      end

      described_class.notify(valuation)
    end

    it 'заголовок summary: маркер отделён « · »' do
      expect(client).to receive(:send_message) do |text, _kwargs|
        expect(text).to include(' · 🧪 ТЕСТ')
        { 'message_id' => 1 }
      end
      expect(client).to receive(:send_document).and_return({ 'message_id' => 2 })

      described_class.notify(valuation)
    end
  end

  describe 'caption боевого аудита (round 5)' do
    it 'без маркера, начинается с «PDF-отчёт»' do
      allow(ENV).to receive(:[]).with('TELEGRAM_AUDITS_CHAT_ID').and_return('-100500')

      expect(client).to receive(:send_message).and_return({ 'message_id' => 1 })
      expect(client).to receive(:send_document) do |_doc, kwargs|
        expect(kwargs[:caption]).to start_with('PDF-отчёт ')
        expect(kwargs[:caption]).not_to include('ТЕСТ')
        { 'message_id' => 2 }
      end

      described_class.notify(valuation)
    end
  end
end
