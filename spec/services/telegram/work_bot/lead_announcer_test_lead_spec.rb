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

    # Находка ревью PR #221 (round 2): route-кнопки у тест-карточки уводили
    # её в рабочую группу через AnchorMigrator (подделанный callback).
    it 'test-лиду не рисуется клавиатура маршрутизации/стадий' do
      announcer = described_class.new(lead, client: client)
      expect(announcer.keyboard_for_card).to be_nil
    end

    it 'AnchorMigrator отказывает test-лиду (route в рабочую группу запрещён)' do
      migrator = Telegram::WorkBot::AnchorMigrator.new(lead, 'appraisal', actor: create(:user), client: client)
      expect(client).not_to receive(:send_message)
      expect(client).not_to receive(:delete_message)

      expect(migrator.call).to be(false)
      expect(lead.reload.anchor_topic_key).to eq('dispatcher')
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

  # Issue #227: Inquiry авто-помечена StaffSubmissionDetector по контактам
  # сотрудника (staff_test=true) БЕЗ явного metadata['test'] — карточка всё
  # равно уходит в тестовый чат, а не в ДИСПЕТЧЕРСКУЮ.
  describe 'маршрутизация по staff_test (issue #227)' do
    let(:staff_inquiry) do
      create(:inquiry, source: 'site_form', staff_test: true, staff_test_matched_by: 'email_staff_match')
    end
    let(:lead) do
      LeadEvent.create!(
        lead_ref:         staff_inquiry,
        source:           'site_form',
        tg_chat_id:       -1_003_779_115_845,
        anchor_topic_key: 'dispatcher',
        current_stage:    'new',
        metadata:         { 'name' => 'Мария', 'phone' => '+79155500011', 'summary' => 'прогон сотрудника' }
      )
    end

    around do |example|
      old = ENV.fetch('TELEGRAM_TEST_CHAT_ID', nil)
      ENV['TELEGRAM_TEST_CHAT_ID'] = '-100999888'
      example.run
      old.nil? ? ENV.delete('TELEGRAM_TEST_CHAT_ID') : ENV['TELEGRAM_TEST_CHAT_ID'] = old
    end

    it 'лид с staff_test публикуется в тестовый чат без message_thread_id' do
      expect(client).to receive(:send_message) do |_text, kwargs|
        expect(kwargs[:chat_id]).to eq(-100_999_888)
        expect(kwargs).not_to have_key(:message_thread_id)
        { 'message_id' => 601 }
      end
      expect(described_class.new(lead, client: client).call).to be(true)
      expect(lead.reload.anchor_message_id).to eq(601)
    end

    it 'рендерит 🧪 ТЕСТ-бейдж для staff_test-лида' do
      announcer = described_class.new(lead, client: client)
      expect(announcer.format_card_text).to include('🧪 <b>ТЕСТ</b>')
    end

    it 'staff_test-лиду не рисуется клавиатура маршрутизации' do
      expect(described_class.new(lead, client: client).keyboard_for_card).to be_nil
    end

    it 'AnchorMigrator отказывает staff_test-лиду (route в рабочую группу запрещён)' do
      migrator = Telegram::WorkBot::AnchorMigrator.new(lead, 'appraisal', actor: create(:user), client: client)
      expect(client).not_to receive(:send_message)
      expect(client).not_to receive(:delete_message)

      expect(migrator.call).to be(false)
      expect(lead.reload.anchor_topic_key).to eq('dispatcher')
    end

    # Rev #230: слабое правило name_staff_first (совпадение только по имени)
    # не основание для изоляции — реальный клиент «Надежда» должен получить
    # боевую карточку в ДИСПЕТЧЕРСКУЮ.
    describe 'staff_test только по name_staff_first (rev #230)' do
      let(:weak_inquiry) do
        create(:inquiry, source: 'site_form', staff_test: true, staff_test_matched_by: 'name_staff_first')
      end
      let(:lead) do
        LeadEvent.create!(
          lead_ref:         weak_inquiry,
          source:           'site_form',
          tg_chat_id:       -1_003_779_115_845,
          anchor_topic_key: 'dispatcher',
          current_stage:    'new',
          metadata:         { 'name' => weak_inquiry.name, 'phone' => weak_inquiry.phone }
        )
      end

      it 'идёт боевым маршрутом в ДИСПЕТЧЕРСКУЮ с топиком' do
        allow(Telegram::TopicRegistry).to receive(:thread_id).and_return(4)
        expect(client).to receive(:send_message) do |_text, kwargs|
          expect(kwargs[:chat_id]).to eq(-1_003_779_115_845)
          expect(kwargs[:message_thread_id]).to eq(4)
          { 'message_id' => 603 }
        end
        expect(described_class.new(lead, client: client).call).to be(true)
      end

      it 'не рендерит ТЕСТ-бейдж' do
        expect(described_class.new(lead, client: client).format_card_text).not_to include('ТЕСТ')
      end

      it 'AnchorMigrator мигрирует такой лид (не тестовый)' do
        migrator = Telegram::WorkBot::AnchorMigrator.new(lead, 'appraisal', actor: create(:user), client: client)
        expect(migrator.send(:test_lead?)).to be(false)
      end
    end

    # lead_ref полиморфный: BuyerOrder/Property staff_test не знают — проверка
    # через respond_to? не должна падать, боевой маршрут не тронут.
    it 'lead_ref без staff_test? (Property) идёт боевым маршрутом' do
      property = create(:property)
      lead = LeadEvent.create!(
        lead_ref:         property,
        source:           'site_form',
        tg_chat_id:       -1_003_779_115_845,
        anchor_topic_key: 'dispatcher',
        current_stage:    'new',
        metadata:         { 'name' => 'Иван', 'phone' => '+79155500022' }
      )
      allow(Telegram::TopicRegistry).to receive(:thread_id).and_return(4)
      expect(client).to receive(:send_message) do |_text, kwargs|
        expect(kwargs[:chat_id]).to eq(-1_003_779_115_845)
        expect(kwargs[:message_thread_id]).to eq(4)
        { 'message_id' => 602 }
      end
      expect(described_class.new(lead, client: client).call).to be(true)
    end
  end
end
