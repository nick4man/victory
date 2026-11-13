# frozen_string_literal: true

require 'rails_helper'

# Issue #227 (rev #230): PDF экспресс-оценки тестового лида не должен
# попадать в рабочую группу — ни reply к anchor (PropertyValuationJob), ни
# fallback-сводка (ExpressReportNotifier). Тест = metadata['test'] ИЛИ
# staff_test по сильному правилу детектора; слабое name_staff_first боевой
# маршрут не меняет.
RSpec.describe 'изоляция PDF экспресс-оценок (issue #227)' do
  let(:client) { instance_double(Telegram::Client) }

  let!(:valuation) do
    Thread.current[:skip_workbot_push] = true
    PropertyValuation.create!(
      property_type: 'apartment', deal_type: 'sale', audit_mode: 'express',
      status: 'completed',
      address: 'г. Рязань, ул. Праволыбедская, д. 24',
      city: 'Рязань', district: 'Железнодорожный',
      latitude: 54.6292, longitude: 39.7417,
      total_area: 44.0, rooms: 2, floor: 4, total_floors: 5,
      estimated_price: 4_400_000,
      evaluation_data: { 'comparables' => [{ 'price' => 1 }] }
    )
  ensure
    Thread.current[:skip_workbot_push] = nil
  end

  before do
    allow(Telegram::Client).to receive(:new).and_return(client)
    allow(PdfGeneratorService).to receive(:new).and_return(instance_double(PdfGeneratorService, call: '%PDF-fake'))
    allow(Telegram::WorkBot::LeadAnnouncer).to receive(:refresh!).and_return(true)
  end

  around do |example|
    old = ENV.fetch('TELEGRAM_TEST_CHAT_ID', nil)
    ENV['TELEGRAM_TEST_CHAT_ID'] = '-100999888'
    example.run
    old.nil? ? ENV.delete('TELEGRAM_TEST_CHAT_ID') : ENV['TELEGRAM_TEST_CHAT_ID'] = old
  end

  describe PropertyValuationJob do
    def push(valuation)
      described_class.new.send(:push_to_lead_card, valuation)
    end

    it 'тест-лид (metadata test=true): PDF reply к anchor в тестовый чат, без топика' do
      lead = LeadEvent.create!(
        lead_ref: valuation, source: 'site_valuation', tg_chat_id: -1_003_779_115_845,
        anchor_topic_key: 'appraisal', anchor_message_id: 900, current_stage: 'new',
        metadata: { 'name' => 'Иван', 'test' => true }
      )
      expect(client).to receive(:send_document) do |_io, kwargs|
        expect(kwargs[:chat_id]).to eq(-100_999_888)
        expect(kwargs[:reply_to_message_id]).to eq(900)
        expect(kwargs).not_to have_key(:message_thread_id)
        expect(kwargs[:caption]).to include('ТЕСТ')
        { 'message_id' => 910 }
      end

      push(valuation)
      expect(lead.reload.anchor_message_id).to eq(900)
    end

    it 'staff_test по сильному правилу: PDF в тестовый чат' do
      valuation.update_columns(staff_test: true, staff_test_matched_by: 'email_staff_match')
      LeadEvent.create!(
        lead_ref: valuation, source: 'site_valuation', tg_chat_id: -1_003_779_115_845,
        anchor_topic_key: 'appraisal', anchor_message_id: 900, current_stage: 'new',
        metadata: { 'name' => 'Иван' }
      )
      expect(client).to receive(:send_document) do |_io, kwargs|
        expect(kwargs[:chat_id]).to eq(-100_999_888)
        { 'message_id' => 911 }
      end

      push(valuation)
    end

    it 'тест-лид без TELEGRAM_TEST_CHAT_ID: PDF пропускается (fail-closed)' do
      ENV.delete('TELEGRAM_TEST_CHAT_ID')
      LeadEvent.create!(
        lead_ref: valuation, source: 'site_valuation', tg_chat_id: -1_003_779_115_845,
        anchor_topic_key: 'appraisal', anchor_message_id: 900, current_stage: 'new',
        metadata: { 'name' => 'Иван', 'test' => true }
      )
      expect(client).not_to receive(:send_document)

      push(valuation)
    end

    it 'staff_test только по name_staff_first: боевой маршрут (рабочая группа + топик)' do
      valuation.update_columns(staff_test: true, staff_test_matched_by: 'name_staff_first')
      LeadEvent.create!(
        lead_ref: valuation, source: 'site_valuation', tg_chat_id: -1_003_779_115_845,
        anchor_topic_key: 'appraisal', anchor_message_id: 900, current_stage: 'new',
        metadata: { 'name' => 'Иван' }
      )
      allow(Telegram::TopicRegistry).to receive_messages(chat_id: -1_003_779_115_845, thread_id: 24)
      expect(client).to receive(:send_document) do |_io, kwargs|
        expect(kwargs[:chat_id]).to eq(-1_003_779_115_845)
        expect(kwargs[:message_thread_id]).to eq(24)
        { 'message_id' => 912 }
      end

      push(valuation)
    end
  end

  describe ExpressReportNotifier do
    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('TELEGRAM_BOT_TOKEN').and_return('bot-token')
    end

    it 'тестовая оценка (metadata test=true): сводка и PDF в тестовый чат, без топика' do
      valuation.update_columns(metadata: { 'test' => true })
      valuation.reload
      expect(client).to receive(:send_message) do |_text, kwargs|
        expect(kwargs[:chat_id]).to eq(-100_999_888)
        expect(kwargs[:message_thread_id]).to be_nil
        { 'message_id' => 920 }
      end
      expect(client).to receive(:send_document) do |_io, kwargs|
        expect(kwargs[:chat_id]).to eq(-100_999_888)
        expect(kwargs[:message_thread_id]).to be_nil
        { 'message_id' => 921 }
      end

      expect(described_class.notify(valuation)).to be(true)
    end

    it 'тестовая оценка без TELEGRAM_TEST_CHAT_ID: пропуск (fail-closed)' do
      ENV.delete('TELEGRAM_TEST_CHAT_ID')
      valuation.update_columns(metadata: { 'test' => true })
      valuation.reload
      expect(client).not_to receive(:send_message)
      expect(client).not_to receive(:send_document)

      expect(described_class.notify(valuation)).to be(false)
    end

    it 'staff_test по сильному правилу: маршрут в тестовый чат' do
      valuation.update_columns(staff_test: true, staff_test_matched_by: 'phone_staff_match')
      valuation.reload
      expect(client).to receive(:send_message).and_return({ 'message_id' => 922 })
      expect(client).to receive(:send_document).and_return({ 'message_id' => 923 })

      expect(described_class.notify(valuation)).to be(true)
    end

    it 'боевой маршрут без изменений (регрессия): рабочая группа + топик ОЦЕНКА' do
      expect(client).to receive(:send_message) do |_text, kwargs|
        expect(kwargs[:chat_id]).to eq(ExpressReportNotifier::DEFAULT_CHAT_ID)
        expect(kwargs[:message_thread_id]).to eq(ExpressReportNotifier::DEFAULT_THREAD_ID)
        { 'message_id' => 924 }
      end
      expect(client).to receive(:send_document) do |_io, kwargs|
        expect(kwargs[:chat_id]).to eq(ExpressReportNotifier::DEFAULT_CHAT_ID)
        { 'message_id' => 925 }
      end

      expect(described_class.notify(valuation)).to be(true)
    end
  end
end
