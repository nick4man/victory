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
      expect {
        described_class.call(source: 'tg_dm', payload: { text: 'снова ищу' },
                             announcer: fake_announcer_class)
      }.to change(LeadEvent, :count).by(1)
    end

    it 'без существующей карточки ведёт себя как раньше — создаёт запись' do
      existing.destroy!
      expect {
        described_class.call(source: 'tg_dm', payload: { text: 'первый раз' },
                             announcer: fake_announcer_class)
      }.to change(LeadEvent, :count).by(1)
    end
  end

end
