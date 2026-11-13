# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lead::Intake do
  let(:fake_announcer_class) do
    Class.new do
      attr_reader :lead, :called

      def self.last
        @last
      end

      def self.reset!
        @last = nil
      end

      def initialize(lead)
        @lead = lead
        @called = false
        self.class.instance_variable_set(:@last, self)
      end

      def call
        @called = true
        true
      end
    end
  end

  before { fake_announcer_class.reset! }

  describe '.call для site_valuation' do
    it 'создаёт LeadEvent + вызывает announcer' do
      result = described_class.call(
        source: 'site_valuation',
        payload: { name: 'Анна', phone: '79001234567', address: 'Ленина 12', area: 54, rooms: 2 },
        announcer: fake_announcer_class
      )
      expect(result).to be_success
      expect(result.lead_event).to be_persisted
      expect(result.lead_event.source).to eq('site_valuation')
      expect(result.lead_event.current_stage).to eq('new')
      expect(result.lead_event.anchor_topic_key).to eq('dispatcher')
      expect(fake_announcer_class.last.called).to be(true)
    end

    it 'сохраняет phone/name/summary в metadata' do
      result = described_class.call(
        source: 'site_form',
        payload: { name: 'Анна', phone: '79001234567', message: 'хочу квартиру' },
        announcer: fake_announcer_class
      )
      meta = result.lead_event.metadata
      expect(meta['name']).to eq('Анна')
      expect(meta['phone']).to eq('+79001234567')
      expect(meta['summary']).to eq('хочу квартиру')
    end
  end

  describe '.call для неподдерживаемого source' do
    it 'возвращает failure без создания LeadEvent' do
      expect {
        result = described_class.call(source: 'wat', payload: {}, announcer: fake_announcer_class)
        expect(result).not_to be_success
        expect(result.error).to include('unsupported source')
      }.not_to change(LeadEvent, :count)
    end
  end

  describe 'обработка исключения в адаптере' do
    it 'возвращает failure и не падает' do
      allow_any_instance_of(Lead::Intake::SiteSource)
        .to receive(:call).and_raise(StandardError, 'boom')

      result = described_class.call(source: 'site_form', payload: {},
                                    announcer: fake_announcer_class)
      expect(result).not_to be_success
      expect(result.error).to include('boom')
    end
  end

  describe 'вернувшийся клиент (cross-channel match)' do
    let(:inquiry) { create(:inquiry, source: 'tg_dm') }
    let!(:existing) do
      LeadEvent.create!(lead_ref: inquiry, source: 'tg_dm', current_stage: 'first_contact',
                        anchor_topic_key: 'apartments', tg_chat_id: -100_123, anchor_message_id: 9001)
    end

    before do
      allow_any_instance_of(Lead::Intake::TgDmSource)
        .to receive(:call)
        .and_return([inquiry, { 'returning_client' => true, 'thread_to_existing_lead' => true, 'channel' => 'tg_dm' }])
    end

    it 'не создаёт второй LeadEvent и возвращает существующий' do
      result = nil
      expect {
        result = described_class.call(source: 'tg_dm', payload: { text: 'ещё вопрос' },
                                     announcer: fake_announcer_class)
      }.not_to change(LeadEvent, :count)

      expect(result).to be_success
      expect(result.lead_event).to eq(existing)
      expect(result).to be_threaded
    end

    it 'не публикует вторую карточку' do
      described_class.call(source: 'tg_dm', payload: { text: 'ещё вопрос' },
                           announcer: fake_announcer_class)
      expect(fake_announcer_class.last).to be_nil
    end

    # Находки ревью PR #65: флаг returning_client перегружен (SiteSource ставит
    # его знакомому клиенту просто для бейджа), и склейка не должна цепляться за
    # закрытые лиды.
    it 'returning_client без thread_to_existing_lead карточку не склеивает' do
      allow_any_instance_of(Lead::Intake::SiteSource)
        .to receive(:call).and_return([inquiry, { 'returning_client' => true }])
      expect {
        described_class.call(source: 'site_form', payload: { text: 'с сайта' },
                             announcer: fake_announcer_class)
      }.to change(LeadEvent, :count).by(1)
      expect(fake_announcer_class.last).not_to be_nil
    end

    it 'закрытый лид не принимает дописку — появляется новая карточка' do
      existing.update!(current_stage: 'closed_lost')
      result = nil
      expect {
        result = described_class.call(source: 'tg_dm', payload: { text: 'снова ищу' },
                                      announcer: fake_announcer_class)
      }.to change(LeadEvent, :count).by(1)
      expect(result).not_to be_threaded
    end

    it 'без существующей карточки ведёт себя как раньше — создаёт запись' do
      existing.destroy!
      expect {
        described_class.call(source: 'tg_dm', payload: { text: 'первый раз' },
                             announcer: fake_announcer_class)
      }.to change(LeadEvent, :count).by(1)
    end
  end

  describe 'тест-лиды (issue #214)' do
    around do |example|
      old = ENV.fetch('TELEGRAM_TEST_CHAT_ID', nil)
      ENV['TELEGRAM_TEST_CHAT_ID'] = '-100999888'
      example.run
      old.nil? ? ENV.delete('TELEGRAM_TEST_CHAT_ID') : ENV['TELEGRAM_TEST_CHAT_ID'] = old
    end

    it 'тест-прогон (payload test: true) → tg_chat_id тестового чата + флаг в metadata' do
      result = described_class.call(
        source: 'site_form',
        payload: { name: 'Тест', phone: '79001234567', message: 'пробный прогон', test: true },
        announcer: fake_announcer_class
      )
      expect(result).to be_success
      expect(result.lead_event.tg_chat_id).to eq(-100_999_888)
      expect(result.lead_event.metadata['test']).to be(true)
    end

    it 'боевой лид идёт в рабочий чат без тест-флага — регрессии нет' do
      allow(Telegram::TopicRegistry).to receive(:chat_id).and_return(-1_003_779_115_845)
      result = described_class.call(
        source: 'site_form',
        payload: { name: 'Анна', phone: '79001234567', message: 'хочу квартиру' },
        announcer: fake_announcer_class
      )
      expect(result.lead_event.tg_chat_id).to eq(-1_003_779_115_845)
      expect(result.lead_event.metadata['test']).to be(false)
    end

    it 'без TELEGRAM_TEST_CHAT_ID тест-лид падает обратно на рабочий chat_id (публикацию LeadAnnouncer скипнет)' do
      ENV.delete('TELEGRAM_TEST_CHAT_ID')
      allow(Telegram::TopicRegistry).to receive(:chat_id).and_return(-1_003_779_115_845)
      result = described_class.call(
        source: 'site_form',
        payload: { name: 'Тест', phone: '79001234567', message: 'пробный прогон', test: true },
        announcer: fake_announcer_class
      )
      expect(result.lead_event.tg_chat_id).to eq(-1_003_779_115_845)
    end

    # Находка ревью PR #221 (round 2): A7 staff-skip резал probe-прогон
    # сотрудника с его боевым телефоном — карточки не было вовсе.
    it 'test-флаг переопределяет staff-skip: agent + test → тестовая карточка создаётся' do
      create(:user, role: :agent, phone: '+79001234567')

      result = described_class.call(
        source: 'site_form',
        payload: { name: 'Сотрудник', phone: '79001234567', message: 'пробный прогон', test: true },
        announcer: fake_announcer_class
      )

      expect(result).to be_success
      expect(result.lead_event).not_to be_nil
      expect(result.lead_event.metadata['test']).to be(true)
      expect(result.lead_event.tg_chat_id).to eq(-100_999_888)
      # fallback-лид тоже помечен тестом — не уйдёт в CRM/агентам
      expect(result.lead_event.lead_ref).to be_test
    end

    it 'боевой маршрут без флага: agent → skip по-прежнему (регрессии нет)' do
      create(:user, role: :agent, phone: '+79001234567')

      result = described_class.call(
        source: 'site_form',
        payload: { name: 'Сотрудник', phone: '79001234567', message: 'боевой сабмит' },
        announcer: fake_announcer_class
      )

      expect(result).to be_success
      expect(result.lead_event).to be_nil
    end

    # Находка ревью PR #221 (round 3): контакты прогона правдоподобны и
    # эвристиками StaffSubmissionDetector не ловятся — изоляция от общего
    # поиска/KPI/embeddings держится на metadata['test'] → staff_test.
    it 'probe-лид с правдоподобными контактами → staff_test=true, без embedding' do
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
      result = described_class.call(
        source: 'site_form',
        payload: { name: 'Мария Соколова', phone: '79031112233', message: 'интересует двушка', test: true },
        announcer: fake_announcer_class
      )
      lead = result.lead_event
      expect(lead.staff_test).to be(true)
      expect(lead.staff_test_matched_by).to eq('lead_test_mode')
      # fallback-Inquiry тоже в том же изоляционном классе
      expect(lead.lead_ref.staff_test).to be(true)
      expect(EmbedLeadEventJob).not_to have_been_enqueued
    end

    it 'боевой лид с теми же контактами → staff_test=false, embedding ставится (регрессии нет)' do
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
      allow(Telegram::TopicRegistry).to receive(:chat_id).and_return(-1_003_779_115_845)
      result = described_class.call(
        source: 'site_form',
        payload: { name: 'Мария Соколова', phone: '79031112233', message: 'интересует двушка' },
        announcer: fake_announcer_class
      )
      lead = result.lead_event
      expect(lead.staff_test).to be(false)
      expect(EmbedLeadEventJob).to have_been_enqueued
    end
  end

  # Issue #227 — ENV-кран SITE_CHATBOT_FORCE_TEST=1 (rev #230: строго про
  # лиды чат-бота — записи с Inquiry source='site_chatbot'; обычные боевые
  # формы сайта кран не задевают).
  describe 'ENV-кран SITE_CHATBOT_FORCE_TEST (issue #227)' do
    around do |example|
      old_flag = ENV.fetch('SITE_CHATBOT_FORCE_TEST', nil)
      old_chat = ENV.fetch('TELEGRAM_TEST_CHAT_ID', nil)
      ENV['SITE_CHATBOT_FORCE_TEST'] = '1'
      ENV['TELEGRAM_TEST_CHAT_ID'] = '-100999888'
      example.run
      old_flag.nil? ? ENV.delete('SITE_CHATBOT_FORCE_TEST') : ENV['SITE_CHATBOT_FORCE_TEST'] = old_flag
      old_chat.nil? ? ENV.delete('TELEGRAM_TEST_CHAT_ID') : ENV['TELEGRAM_TEST_CHAT_ID'] = old_chat
    end

    it 'прогон чат-бота (Inquiry source=site_chatbot) → metadata test=true, tg_chat_id тестового чата' do
      inquiry = create(:inquiry, source: 'site_chatbot')

      result = described_class.call(
        source: 'site_form',
        payload: { name: inquiry.name, phone: inquiry.phone, message: 'интересует двушка', inquiry_id: inquiry.id },
        announcer: fake_announcer_class
      )
      expect(result).to be_success
      expect(result.lead_event.metadata['test']).to be(true)
      expect(result.lead_event.tg_chat_id).to eq(-100_999_888)
    end

    it 'кран: прогон чат-бота помечается staff_test и не ставится embedding' do
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
      inquiry = create(:inquiry, source: 'site_chatbot')

      result = described_class.call(
        source: 'site_form',
        payload: { name: inquiry.name, phone: inquiry.phone, message: 'интересует двушка', inquiry_id: inquiry.id },
        announcer: fake_announcer_class
      )
      expect(result.lead_event.staff_test).to be(true)
      expect(result.lead_event.staff_test_matched_by).to eq(StaffSubmissionDetector::TEST_MODE_MATCHED_BY)
      expect(EmbedLeadEventJob).not_to have_been_enqueued
    end

    it 'узкий кран: обычная контактная форма (Inquiry source=site_form) боевым маршрутом не тронута' do
      allow(Telegram::TopicRegistry).to receive(:chat_id).and_return(-1_003_779_115_845)
      inquiry = create(:inquiry, source: 'site_form')

      result = described_class.call(
        source: 'site_form',
        payload: { name: inquiry.name, phone: inquiry.phone, message: 'хочу квартиру', inquiry_id: inquiry.id },
        announcer: fake_announcer_class
      )
      expect(result.lead_event.metadata['test']).to be(false)
      expect(result.lead_event.tg_chat_id).to eq(-1_003_779_115_845)
    end

    # Кран про чат-бот сайта: tg_dm-лиды боевым маршрутом не тронуты.
    it 'tg_dm краном не помечается' do
      result = described_class.call(
        source: 'tg_dm',
        payload: { text: 'вопрос по ипотеке из крана', tg_user_id: 777_001, first_name: 'Мария' },
        announcer: fake_announcer_class
      )
      expect(result.lead_event.metadata).not_to have_key('test')
    end
  end

  # Issue #227 — маршрутизация по staff_test: Inquiry авто-детектed по email
  # сотрудника (StaffSubmissionDetector), флага в payload нет.
  describe 'маршрутизация по staff_test (issue #227)' do
    around do |example|
      old = ENV.fetch('TELEGRAM_TEST_CHAT_ID', nil)
      ENV['TELEGRAM_TEST_CHAT_ID'] = '-100999888'
      example.run
      old.nil? ? ENV.delete('TELEGRAM_TEST_CHAT_ID') : ENV['TELEGRAM_TEST_CHAT_ID'] = old
    end

    it 'lead_ref staff_test=true → metadata test=true, тестовый tg_chat_id' do
      inquiry = create(:inquiry, source: 'site_form', staff_test: true, staff_test_matched_by: 'email_staff_match')

      result = described_class.call(
        source: 'site_form',
        payload: { name: inquiry.name, phone: inquiry.phone, message: 'прогон сотрудника', inquiry_id: inquiry.id },
        announcer: fake_announcer_class
      )

      expect(result).to be_success
      expect(result.lead_event.metadata['test']).to be(true)
      expect(result.lead_event.tg_chat_id).to eq(-100_999_888)
      expect(result.lead_event.lead_ref).to eq(inquiry)
    end

    it 'боевой lead_ref (staff_test=false) краном staff_test не помечается' do
      allow(Telegram::TopicRegistry).to receive(:chat_id).and_return(-1_003_779_115_845)
      inquiry = create(:inquiry, source: 'site_form')

      result = described_class.call(
        source: 'site_form',
        payload: { name: inquiry.name, phone: inquiry.phone, message: 'хочу квартиру', inquiry_id: inquiry.id },
        announcer: fake_announcer_class
      )

      expect(result.lead_event.metadata['test']).to be(false)
      expect(result.lead_event.tg_chat_id).to eq(-1_003_779_115_845)
    end

    # Rev #230: слабое правило name_staff_first (совпадение только по имени)
    # не основание для жёсткой изоляции — реальный клиент «Надежда» должен
    # остаться на боевом маршруте.
    it 'lead_ref staff_test только по name_staff_first → боевой маршрут без metadata test' do
      allow(Telegram::TopicRegistry).to receive(:chat_id).and_return(-1_003_779_115_845)
      inquiry = create(:inquiry, source: 'site_form', staff_test: true, staff_test_matched_by: 'name_staff_first')

      result = described_class.call(
        source: 'site_form',
        payload: { name: inquiry.name, phone: inquiry.phone, message: 'хочу квартиру', inquiry_id: inquiry.id },
        announcer: fake_announcer_class
      )

      expect(result.lead_event.metadata['test']).to be(false)
      expect(result.lead_event.tg_chat_id).to eq(-1_003_779_115_845)
    end
  end

end
