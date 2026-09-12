# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Callbacks::SegmentCallback do
  let(:tg_client) do
    instance_double(Telegram::Client,
                    edit_message_text: { 'message_id' => 9000 },
                    answer_callback_query: { 'ok' => true })
  end
  let(:agent)  { TelegramUser.create!(tg_user_id: 111, role: 'agent', first_name: 'A', is_manager: false, status: 'active') }
  let(:other)  { TelegramUser.create!(tg_user_id: 222, role: 'agent', first_name: 'B', is_manager: false, status: 'active') }
  let(:director) do
    TelegramUser.create!(tg_user_id: 333, role: 'director', first_name: 'O', is_manager: false, status: 'active')
  end
  let!(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'tg_dm', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_123, anchor_message_id: 9000, assigned_to: agent)
  end

  def run(data, user: agent)
    cb = { 'id' => 'cb-1', 'data' => data, 'from' => { 'id' => user.tg_user_id },
           'message' => { 'message_id' => 9000, 'chat' => { 'id' => -100_123, 'type' => 'supergroup' } } }
    described_class.new(callback_query: cb, tg_user: user, args: data.split(':').drop(1), client: tg_client).call
  end

  it 'assignee ставит сегмент и карточка перерисовывается' do
    run("segment:#{lead.id}:cash")
    expect(lead.reload.segment).to eq('cash')
    expect(tg_client).to have_received(:edit_message_text)
      .with(a_string_including('💵 Наличные'), hash_including(chat_id: -100_123, message_id: 9000))
    expect(tg_client).to have_received(:answer_callback_query).with('cb-1', hash_including(text: a_string_including('Наличные')))
  end

  it 'директор без is_manager тоже может (gotcha: manager_only в Callbacks::Base смотрит только is_manager)' do
    run("segment:#{lead.id}:cold", user: director)
    expect(lead.reload.segment).to eq('cold')
  end

  it 'чужой агент получает alert и ничего не меняет' do
    run("segment:#{lead.id}:cold", user: other)
    expect(lead.reload.segment).to be_nil
    expect(tg_client).to have_received(:answer_callback_query).with('cb-1', hash_including(show_alert: true))
  end

  it 'неизвестное значение → alert' do
    run("segment:#{lead.id}:vip")
    expect(lead.reload.segment).to be_nil
    expect(tg_client).to have_received(:answer_callback_query).with('cb-1', hash_including(show_alert: true))
  end

  it 'повторное нажатие того же сегмента — не ошибка, карточку не трогает' do
    lead.update!(segment: 'cash')
    run("segment:#{lead.id}:cash")
    expect(tg_client).not_to have_received(:edit_message_text)
    expect(tg_client).to have_received(:answer_callback_query).with('cb-1', hash_including(text: a_string_including('Уже')))
  end
end
