# frozen_string_literal: true

require 'rails_helper'

# Review round 6 (PR #228) — центральный инвариант: резолверы
# (resolve_lead!/find_lead_via_reply) отказывают для staff_test-лидов
# ВСЕМ командам, а не только /assign /task /stage из round 5.
# Раньше /bargain слал DM руководителям, /show создавал боевой ShowReport
# (→ Task + LeadStageTransition), /close вёл в CloseFlow — обходя гейт.
RSpec.describe 'staff_test-изоляция: все команды с резолвером лида' do
  let(:tg_client) { instance_double(Telegram::Client, send_message: { 'message_id' => 1 }) }
  let(:agent) { TelegramUser.create!(tg_user_id: 111, role: 'agent', first_name: 'Ирина', status: 'active', dm_chat_id: 111) }
  let!(:test_lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'new',
                      anchor_topic_key: 'dispatcher', tg_chat_id: -100_1, anchor_message_id: 900,
                      staff_test: true, metadata: { 'name' => 'Тест' })
  end

  def run_command(klass, args, msg_overrides = {})
    msg = { 'chat' => { 'id' => 111, 'type' => 'private' }, 'from' => { 'id' => 111 },
            'message_id' => 5, 'text' => "/cmd #{args}" }.merge(msg_overrides)
    klass.new(message: msg, args: args, tg_user: agent, client: tg_client).send(:handle)
  end

  def expect_refusal
    expect(tg_client).to have_received(:send_message)
      .with(a_string_including('тестовый'), hash_including(:chat_id)).once
  end

  it '/bargain по id тест-лида — отказ, без DM руководителям' do
    run_command(Telegram::WorkBot::Commands::Bargain, "#{test_lead.id} 5200000")
    expect_refusal
  end

  it '/show по id тест-лида — отказ, ShowReport не создаётся' do
    intake = instance_double(Telegram::WorkBot::ShowReports::Intake)
    allow(Telegram::WorkBot::ShowReports::Intake).to receive(:new).and_return(intake)
    run_command(Telegram::WorkBot::Commands::Show, "#{test_lead.id} показ прошёл")
    expect_refusal
    expect(Telegram::WorkBot::ShowReports::Intake).not_to have_received(:new)
  end

  it '/note по id тест-лида — отказ, заметка не пишется' do
    run_command(Telegram::WorkBot::Commands::Note, "#{test_lead.id} тестовая заметка")
    expect_refusal
    expect(test_lead.reload.metadata['notes']).to be_blank
  end

  it '/route по id тест-лида — отказ' do
    run_command(Telegram::WorkBot::Commands::Route, "#{test_lead.id} apartments")
    expect_refusal
  end

  it '/objections по id тест-лида — отказ' do
    run_command(Telegram::WorkBot::Commands::Objections, test_lead.id.to_s)
    expect_refusal
  end

  it '/segment по id тест-лида — отказ' do
    run_command(Telegram::WorkBot::Commands::Segment, "#{test_lead.id} наличные")
    expect_refusal
  end

  it '/close по id тест-лида — отказ, мастер не открывается' do
    expect(Telegram::WorkBot::Wizard::Engine).not_to receive(:new)
    run_command(Telegram::WorkBot::Commands::Close, "#{test_lead.id} выиграно")
    expect_refusal
  end

  it '/unstage reply на карточку тест-лида — отказ, стадия не меняется' do
    test_lead.update!(current_stage: 'first_contact', metadata: test_lead.metadata.merge(
      'stage_history' => [{ 'at' => Time.current.iso8601, 'from' => 'new', 'to' => 'first_contact' }]
    ))
    run_command(Telegram::WorkBot::Commands::Unstage, '',
                'chat' => { 'id' => -100_1, 'type' => 'supergroup' },
                'reply_to_message' => { 'message_id' => 900 })
    expect_refusal
    expect(test_lead.reload.current_stage).to eq('first_contact')
  end

  it '/show reply на карточку тест-лида — тоже отказ (reply-ветка под гейтом)' do
    run_command(Telegram::WorkBot::Commands::Show, 'показ прошёл',
                'chat' => { 'id' => -100_1, 'type' => 'supergroup' },
                'reply_to_message' => { 'message_id' => 900 })
    expect_refusal
  end

  it '/doc reply на карточку тест-лида — отказ, DocumentChecklist не вызывается (round 7)' do
    expect(DocumentChecklist::Builder).not_to receive(:new)
    run_command(Telegram::WorkBot::Commands::Doc, 'init',
                'chat' => { 'id' => -100_1, 'type' => 'supergroup' },
                'reply_to_message' => { 'message_id' => 900 })
    expect_refusal
  end

  it 'боевой лид по-прежнему проходит (гейт не задевает обычную работу)' do
    real = LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'new',
                             anchor_topic_key: 'dispatcher', tg_chat_id: -100_1, anchor_message_id: 901)
    run_command(Telegram::WorkBot::Commands::Objections, real.id.to_s)
    expect(tg_client).not_to have_received(:send_message).with(a_string_including('тестовый'), anything)
  end
end
