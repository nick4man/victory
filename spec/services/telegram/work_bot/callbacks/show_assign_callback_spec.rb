# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Callbacks::ShowAssignCallback do
  let(:tg_client) do
    instance_double(Telegram::Client, send_message: { 'message_id' => 1 }, edit_message_text: { 'message_id' => 1 },
                                      answer_callback_query: { 'ok' => true })
  end
  let(:agent)    { TelegramUser.create!(tg_user_id: 111, role: 'agent', first_name: 'Ирина', status: 'active', dm_chat_id: 111) }
  let(:director) { TelegramUser.create!(tg_user_id: 333, role: 'director', first_name: 'Оксана', status: 'active', dm_chat_id: 333) }
  let(:property) { create(:property, address: 'Рязань, ул. Есенина, 12') }
  let!(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'tg_dm', current_stage: 'show', anchor_topic_key: 'apartments',
                      tg_chat_id: -100_1, anchor_message_id: 900, assigned_to: agent, segment: 'cold', property: property)
  end

  def run(target, user: agent)
    data = "show_assign:#{lead.id}:#{target.id}"
    cb = { 'id' => 'cb-1', 'data' => data, 'from' => { 'id' => user.tg_user_id },
           'message' => { 'message_id' => 55, 'text' => 'Кто поедет', 'chat' => { 'id' => -100_1, 'type' => 'supergroup' } } }
    described_class.new(callback_query: cb, tg_user: user, args: data.split(':').drop(1), client: tg_client).call
  end

  it 'назначает показывающего: metadata, Task kind show на него, DM ему, клавиатура снята' do
    run(director)
    lead.reload
    expect(lead.metadata['show_conductor_id']).to eq(director.id)
    task = Task.find_by(lead_event: lead, kind: 'show')
    expect(task.assignee).to eq(director)
    expect(task.title).to include('Есенина')
    expect(tg_client).to have_received(:send_message).with(a_string_including('Показ', 'Есенина'), hash_including(chat_id: 333))
    expect(tg_client).to have_received(:edit_message_text)
      .with(a_string_including('Оксана'), hash_including(message_id: 55, reply_markup: { inline_keyboard: [] }))
  end

  it 'повторное нажатие на того же — «уже»' do
    run(director)
    run(director)
    expect(Task.where(lead_event: lead, kind: 'show').count).to eq(1)
    expect(tg_client).to have_received(:answer_callback_query).with('cb-1', hash_including(text: a_string_including('Уже')))
  end

  it 'чужой агент → alert' do
    other = TelegramUser.create!(tg_user_id: 222, role: 'agent', first_name: 'Б', status: 'active')
    run(director, user: other)
    expect(lead.reload.metadata['show_conductor_id']).to be_nil
  end

  it 'неизвестный сотрудник → alert' do
    data = "show_assign:#{lead.id}:999999"
    cb = { 'id' => 'cb-1', 'data' => data, 'from' => { 'id' => agent.tg_user_id },
           'message' => { 'message_id' => 55, 'chat' => { 'id' => -100_1 } } }
    described_class.new(callback_query: cb, tg_user: agent, args: data.split(':').drop(1), client: tg_client).call
    expect(tg_client).to have_received(:answer_callback_query).with('cb-1', hash_including(show_alert: true))
  end
end
