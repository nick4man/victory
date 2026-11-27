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
  end
end
