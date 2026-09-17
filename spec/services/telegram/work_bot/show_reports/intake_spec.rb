# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::ShowReports::Intake do
  let(:tg_client) { instance_double(Telegram::Client, send_message: { 'message_id' => 505 }) }
  let(:agent)     { TelegramUser.create!(tg_user_id: 111, role: 'agent', first_name: 'Ирина', status: 'active', dm_chat_id: 111) }
  let!(:director) { TelegramUser.create!(tg_user_id: 333, role: 'director', first_name: 'Оксана', status: 'active') }
  let(:property)  { create(:property) }
  let!(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'tg_dm', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1, assigned_to: agent, property: property)
  end
  let(:extractor) { class_double(Telegram::WorkBot::ShowReports::Extractor) }

  def extraction(overrides = {})
    Telegram::WorkBot::ShowReports::Extractor::Result.new({
      lead_id: lead.id, conducted_by_director: true, conducted_at: Time.current, outcome: 'thinking',
      objections: ['кухня'], offered_price: nil, next_step: nil, owner_message: 'Добрый день!',
      uncertainties: [], model: 'stub', error: nil
    }.merge(overrides))
  end

  def run(lead_arg: nil, transcript: 'показ Есенина, кухня не понравилась')
    described_class.new(reporter: agent, transcript_raw: transcript, transcript_redacted: transcript,
                        source: 'voice', chat_id: 111, lead: lead_arg, client: tg_client, extractor: extractor).call
  end

  it 'счастливый путь: pending ShowReport + превью' do
    allow(extractor).to receive(:call).and_return(extraction)
    res = run
    expect(res.ok).to be(true)
    report = res.report
    expect(report.status_pending_confirm?).to be(true)
    expect(report.conducted_by).to eq(director)
    expect(report.property).to eq(property)
    expect(report.transcript_redacted).to be_present
    expect(tg_client).to have_received(:send_message).with(a_string_including('Подтверди'), anything)
  end

  it 'conducted_by_director=false → показывал рассказчик' do
    allow(extractor).to receive(:call).and_return(extraction(conducted_by_director: false))
    expect(run.report.conducted_by).to eq(agent)
  end

  it 'явный lead: (из /show) — в extractor уходит только он' do
    allow(extractor).to receive(:call).and_return(extraction)
    run(lead_arg: lead)
    expect(extractor).to have_received(:call).with(hash_including(candidates: [lead]))
  end

  it 'лид не определён → ok:false с подсказкой и списком открытых лидов, записи нет' do
    allow(extractor).to receive(:call).and_return(extraction(lead_id: nil, uncertainties: ['не понял лид']))
    res = run
    expect(res.ok).to be(false)
    expect(res.message).to include('/show', "/show #{lead.id}")
    expect(ShowReport.count).to eq(0)
  end

  it 'у рассказчика уже есть неподтверждённый отчёт → отказ с номером' do
    ShowReport.create!(lead_event: lead, conducted_by: director, reported_by: agent, conducted_at: Time.current, source: 'voice')
    allow(extractor).to receive(:call).and_return(extraction)
    res = run
    expect(res.ok).to be(false)
    expect(res.message).to include('неподтверждённый')
  end

  # Находка ревью PR #65: pending-строка без доставленного превью блокировала
  # все следующие отчёты на час, и нажать было нечего.
  it 'превью не доставлено → отчёт снят, следующий отчёт не заблокирован' do
    allow(extractor).to receive(:call).and_return(extraction)
    allow(tg_client).to receive(:send_message).and_raise(Telegram::Client::Error, 'bot was blocked')

    res = run
    expect(res.ok).to be(false)
    expect(res.message).to include('личку с ботом')
    expect(ShowReport.status_pending_confirm.count).to eq(0)
    expect(ShowReport.unscoped.last.status_cancelled?).to be(true)
  end

  it 'ошибка extractor → ok:false, текст ошибки' do
    allow(extractor).to receive(:call).and_return(extraction(error: 'LLM down'))
    expect(run.message).to include('LLM down')
  end

  it 'закрытый лид не попадает в кандидаты' do
    lead.update!(current_stage: 'closed_lost')
    expect(described_class.candidates_for(agent)).to be_empty
  end

  it 'директор видит кандидатов всех агентов' do
    expect(described_class.candidates_for(director)).to include(lead)
  end
end
