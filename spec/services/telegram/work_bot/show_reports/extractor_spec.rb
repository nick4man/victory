# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::ShowReports::Extractor do
  # Стаб OmniClient в стиле voice_intent_branch_spec — DI через client:.
  class StubOmniForShowReport # rubocop:disable Lint/ConstantDefinitionInBlock
    attr_reader :last_messages

    def initialize(content: nil, raise: nil)
      @content = content
      @raise = raise
    end

    def complete(messages, **_opts)
      @last_messages = messages
      raise @raise if @raise

      { content: @content, model: 'stub' }
    end
  end

  let(:agent) { TelegramUser.create!(tg_user_id: 111, role: 'agent', first_name: 'Ирина', status: 'active') }
  let(:property) { create(:property, address: 'Рязань, ул. Есенина, 12', price: 5_500_000) }
  let(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'tg_dm', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1, assigned_to: agent,
                      property: property, metadata: { 'name' => 'Анна' })
  end
  let(:now) { Time.zone.parse('2026-09-11 15:00') }

  def payload(overrides = {})
    {
      lead_id: lead.id, conducted_by_director: true, conducted_at: '2026-09-11T14:00:00',
      outcome: 'thinking', objections: ['Маленькая кухня', 'первый этаж'], offered_price: nil,
      next_step: 'перезвонят в пятницу',
      owner_message: 'Анна Петровна, добрый день! Оксана провела показ...', uncertainties: []
    }.merge(overrides).to_json
  end

  it 'раскладывает валидный JSON в Result' do
    client = StubOmniForShowReport.new(content: payload)
    res = described_class.call(transcript: 'Показ Есенина 12, Оксана показывала, кухня не понравилась',
                               candidates: [lead], reporter: agent, now: now, client: client)
    expect(res).to be_success
    expect(res.lead_id).to eq(lead.id)
    expect(res.conducted_by_director).to be(true)
    expect(res.outcome).to eq('thinking')
    expect(res.objections).to eq(['маленькая кухня', 'первый этаж'])
    expect(res.conducted_at).to eq(Time.zone.parse('2026-09-11 14:00'))
    expect(res.owner_message).to include('Оксана')
  end

  it 'кандидаты уходят в промпт с id и адресом' do
    client = StubOmniForShowReport.new(content: payload)
    described_class.call(transcript: 'x', candidates: [lead], reporter: agent, now: now, client: client)
    system = client.last_messages.first[:content]
    expect(system).to include("##{lead.id}").and include('Есенина')
  end

  it 'lead_id вне кандидатов → nil + uncertainty' do
    client = StubOmniForShowReport.new(content: payload(lead_id: 999_999))
    res = described_class.call(transcript: 'x', candidates: [lead], reporter: agent, now: now, client: client)
    expect(res.lead_id).to be_nil
    expect(res.uncertainties.join).to include('лид')
  end

  it 'неизвестный outcome → thinking; цена «5,2 млн» → 5200000' do
    client = StubOmniForShowReport.new(content: payload(outcome: 'happy', offered_price: '5,2 млн'))
    res = described_class.call(transcript: 'x', candidates: [lead], reporter: agent, now: now, client: client)
    expect(res.outcome).to eq('thinking')
    expect(res.offered_price).to eq(5_200_000)
  end

  it 'conducted_at в будущем или битая → now' do
    client = StubOmniForShowReport.new(content: payload(conducted_at: 'вчера вечером'))
    res = described_class.call(transcript: 'x', candidates: [lead], reporter: agent, now: now, client: client)
    expect(res.conducted_at).to eq(now)
  end

  it 'пустой owner_message → шаблонный черновик из исхода и возражений' do
    client = StubOmniForShowReport.new(content: payload(owner_message: ''))
    res = described_class.call(transcript: 'x', candidates: [lead], reporter: agent, now: now, client: client)
    expect(res.owner_message).to include('кухня')
  end

  it 'LLM упал → error, не исключение' do
    client = StubOmniForShowReport.new(raise: StandardError.new('down'))
    res = described_class.call(transcript: 'x', candidates: [lead], reporter: agent, now: now, client: client)
    expect(res).not_to be_success
    expect(res.error).to include('down')
  end

  it 'не JSON → error' do
    client = StubOmniForShowReport.new(content: 'ага')
    res = described_class.call(transcript: 'x', candidates: [lead], reporter: agent, now: now, client: client)
    expect(res).not_to be_success
  end
end
