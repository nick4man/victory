# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::LeadAnnouncer do
  # Репро issue #275 (КРАСНЫЙ spec до фикса): якорная карточка лида в
  # ДИСПЕТЧЕРСКОЙ не показывает IP/user_agent источника, хотя Inquiry их
  # хранит (формы сайта пишут request.remote_ip, чат — Llm::SpamFilter).
  # Спам-триаж и кнопка [🚫 Спам] из-за этого опираются на догадки, а не
  # на факты.
  #
  # Payload в Lead::Intake намеренно зеркалит Inquiry#push_to_work_bot:
  # IP живёт на Inquiry (lead_ref), а не в payload. Реализация может читать
  # его из lead_ref напрямую или прокидывать в meta через SiteSource —
  # spec фиксирует только видимый результат на карточке.
  let(:client) { instance_double(Telegram::Client) }

  # Заглушка announcer'а для Lead::Intake: LeadEvent создаётся боевым путём,
  # а публикация в TG не нужна — карточку рендерим ниже сами.
  let(:null_announcer) do
    Class.new do
      def initialize(*)
        nil
      end

      def call
        true
      end
    end
  end

  def intake_lead(inquiry)
    result = Lead::Intake.call(
      source: 'site_form',
      payload: {
        name: inquiry.name, phone: inquiry.phone, email: inquiry.email,
        message: inquiry.message, summary: inquiry.message,
        inquiry_id: inquiry.id, origin: inquiry.referrer_url
      }.compact,
      announcer: null_announcer
    )
    expect(result).to be_success
    result.lead_event
  end

  def card_text(lead)
    described_class.new(lead, client: client).format_card_text
  end

  describe 'IP и user_agent источника на карточке лида (issue #275)' do
    let(:ip) { '80.94.95.202' }
    let(:user_agent) { 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/131.0.0.0' }

    it 'показывает IP и user_agent, когда они заполнены на Inquiry' do
      inquiry = create(:inquiry, source: 'site_form', ip_address: ip, user_agent: user_agent)
      text = card_text(intake_lead(inquiry))

      expect(text).to include(ip)
      expect(text).to include(user_agent)
    end

    it 'показывает IP, когда user_agent не заполнен' do
      inquiry = create(:inquiry, source: 'site_form', ip_address: ip, user_agent: nil)
      text = card_text(intake_lead(inquiry))

      expect(text).to include(ip)
    end

    it 'без IP на Inquiry карточка рендерится как раньше (контроль)' do
      inquiry = create(:inquiry, source: 'site_form')
      text = card_text(intake_lead(inquiry))

      expect(text).to include('Новый лид')
      expect(text).not_to include(ip)
    end

    # Нит ревью #278: короткий безопасный UA не фиксировал заявленные в PR
    # обрезку до 80 и HTML-экранирование — проверяем итоговую строку целиком.
    it 'длинный UA с HTML-символами: обрезка до 80 и экранирование одновременно' do
      raw_ua = '<b>&' + 'x' * 90 # 94 символа
      inquiry = create(:inquiry, source: 'site_form', ip_address: ip, user_agent: raw_ua)
      text = card_text(intake_lead(inquiry))

      # truncate(80) оставляет 77 символов + '...' (omission входит в лимит),
      # затем escape(&, <, >). Строка целиком фиксирует и границу длины,
      # и отсутствие HTML-инъекции.
      expected = "🌐 IP: #{ip} · &lt;b&gt;&amp;#{'x' * 73}..."
      expect(text).to include(expected)
      expect(text).not_to include('<b>&')
    end

    # Блокер ревью #278: lead_ref чатового лида — PropertyValuation из
    # EstimatePropertyValuation, которая до #275 писала технические
    # 0.0.0.0/chat-bot. Placeholder не должен показываться как факт источника.
    context 'когда lead_ref — PropertyValuation чатовой оценки' do
      def create_chat_valuation(ip:, ua:)
        # after_create_commit push гасим — карточку рендерим ниже сами
        Thread.current[:skip_workbot_push] = true
        PropertyValuation.create!(
          property_type: 'apartment', deal_type: 'sale',
          address: 'г. Рязань, ул. Чатовая, д. 5', total_area: 54, rooms: 2,
          # координаты заданы — resolve_coordinates не ходит в геокодер (WebMock)
          latitude: 54.6292, longitude: 39.7417,
          status: 'completed', ip_address: ip, user_agent: ua
        )
      ensure
        Thread.current[:skip_workbot_push] = false
      end

      def intake_valuation_lead(pv)
        result = Lead::Intake.call(
          source: 'site_valuation',
          payload: {
            name: 'Клиент Чата', phone: '79001112233',
            address: pv.address, area: pv.total_area, rooms: pv.rooms,
            valuation_id: pv.id
          },
          announcer: null_announcer
        )
        expect(result).to be_success
        result.lead_event
      end

      it 'реальный IP/UA чатовой оценки показывается на карточке' do
        pv = create_chat_valuation(ip: '203.0.113.10', ua: 'Mozilla/5.0 (ChatWidget)')
        text = card_text(intake_valuation_lead(pv))

        expect(text).to include('203.0.113.10')
        expect(text).to include('Mozilla/5.0 (ChatWidget)')
      end

      it 'sentinel-заглушки 0.0.0.0/chat-bot не выводятся как факт — строка опускается' do
        pv = create_chat_valuation(ip: '0.0.0.0', ua: 'chat-bot')
        text = card_text(intake_valuation_lead(pv))

        expect(text).to include('Новый лид')
        expect(text).not_to include('0.0.0.0')
        expect(text).not_to include('chat-bot')
      end
    end
  end
end
