# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Callbacks::ShowReportCallback do
  let(:tg_client) do
    instance_double(Telegram::Client,
                    send_message: { 'message_id' => 1 }, edit_message_text: { 'message_id' => 1 },
                    answer_callback_query: { 'ok' => true })
  end
  let(:agent)    { TelegramUser.create!(tg_user_id: 111, role: 'agent', first_name: 'Ирина', status: 'active', dm_chat_id: 111) }
  let(:other)    { TelegramUser.create!(tg_user_id: 222, role: 'agent', first_name: 'Б', status: 'active', dm_chat_id: 222) }
  let!(:director) { TelegramUser.create!(tg_user_id: 333, role: 'director', first_name: 'Оксана', status: 'active') }
  let(:owner)    { create(:user, :tg_linked) }
  let(:property) { create(:property, owner_user: owner) }
  let(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'tg_dm', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1, anchor_message_id: 900,
                      assigned_to: agent, property: property)
  end
  let!(:report) do
    ShowReport.create!(lead_event: lead, property: property, conducted_by: director, reported_by: agent,
                       conducted_at: Time.current, source: 'voice', owner_message: 'Добрый день!',
                       preview_message_id: 505, preview_chat_id: 111)
  end

  # BOTTLENECK — время фиксировано намеренно: owner_push уважает тихие часы
  # (21:00–07:00 МСК), и без travel_to спека падала бы при ночном прогоне CI.
  before { travel_to(Time.find_zone('Europe/Moscow').local(2026, 9, 11, 14, 0)) }

  def run(action, user: agent)
    data = "show_report:#{report.id}:#{action}"
    cb = { 'id' => 'cb-1', 'data' => data, 'from' => { 'id' => user.tg_user_id },
           'message' => { 'message_id' => 505, 'text' => 'превью', 'chat' => { 'id' => user.dm_chat_id, 'type' => 'private' } } }
    described_class.new(callback_query: cb, tg_user: user, args: data.split(':').drop(1), client: tg_client).call
  end

  it 'approve → подтверждён, превью помечено ✅, клавиатура снята' do
    run('approve')
    expect(report.reload.status_confirmed?).to be(true)
    expect(tg_client).to have_received(:edit_message_text)
      .with(a_string_including('Сохранено'), hash_including(message_id: 505, reply_markup: { inline_keyboard: [] }))
  end

  it 'cancel → отменён, превью помечено ✖️' do
    run('cancel')
    expect(report.reload.status_cancelled?).to be(true)
    expect(tg_client).to have_received(:edit_message_text).with(a_string_including('Отменено'), anything)
  end

  it 'toggle_conductor → показывающий меняется и превью перерисовывается целиком' do
    run('toggle_conductor')
    expect(report.reload.conducted_by).to eq(agent)
    expect(tg_client).to have_received(:edit_message_text)
      .with(a_string_including('Ирина'), hash_including(message_id: 505, reply_markup: hash_including(:inline_keyboard)))
  end

  it 'чужой пользователь → alert' do
    run('approve', user: other)
    expect(report.reload.status_pending_confirm?).to be(true)
    expect(tg_client).to have_received(:answer_callback_query).with('cb-1', hash_including(show_alert: true))
  end

  it 'approve дважды → второй раз «уже»' do
    run('approve')
    run('approve')
    expect(tg_client).to have_received(:answer_callback_query).with('cb-1', hash_including(text: a_string_including('Уже')))
  end

  context 'после подтверждения' do
    before { run('approve') }

    it 'owner_push шлёт собственнику через PushToClient, закрывает задачу, фиксирует канал' do
      push = instance_double(Telegram::PushToClient::Result, success?: true, error: nil)
      allow(Telegram::PushToClient).to receive(:send).and_return(push)
      run('owner_push')
      expect(Telegram::PushToClient).to have_received(:send).with(user: owner, message: a_string_including('Добрый день!'))
      report.reload
      expect(report.owner_notified_via).to eq('tg')
      expect(report.owner_notified_at).to be_present
      expect(Task.find(report.feedback_task_id).status_done?).to be(true)
    end

    it 'owner_push при отказе Telegram → alert, задача открыта' do
      push = instance_double(Telegram::PushToClient::Result, success?: false, error: 'bot was blocked')
      allow(Telegram::PushToClient).to receive(:send).and_return(push)
      run('owner_push')
      expect(report.reload.owner_notified_at).to be_nil
      expect(tg_client).to have_received(:answer_callback_query).with('cb-1', hash_including(show_alert: true))
    end

    it 'owner_sent закрывает задачу вручную (acked_method button)' do
      run('owner_sent')
      task = Task.find(report.reload.feedback_task_id)
      expect(task.status_done?).to be(true)
      expect(task.acked_method_button?).to be(true)
      expect(report.owner_notified_via).to eq('manual')
    end

    describe 'тихие часы' do
      it 'в 22:30 МСК собственнику не уходит, отметки нет' do
        travel_to(Time.find_zone('Europe/Moscow').local(2026, 9, 11, 22, 30))
        expect(Telegram::PushToClient).not_to receive(:send)
        run('owner_push')
        expect(report.reload.owner_notified_at).to be_nil
        expect(tg_client).to have_received(:answer_callback_query).with('cb-1', hash_including(show_alert: true))
      end

      it 'в 10:00 МСК уходит' do
        travel_to(Time.find_zone('Europe/Moscow').local(2026, 9, 12, 10, 0))
        push = instance_double(Telegram::PushToClient::Result, success?: true, error: nil)
        allow(Telegram::PushToClient).to receive(:send).and_return(push)
        run('owner_push')
        expect(report.reload.owner_notified_at).to be_present
      end
    end
  end
end
