# frozen_string_literal: true

require 'rails_helper'

# Review round 7 (PR #228) — центральный гейт Callbacks::Base#lead_event:
# staff_test-лиды (probe-прогоны) недоступны НИ ОДНОМУ callback'у. Раньше
# guard был только в stage/assign_to — show_assign создавал боевой Task с DM,
# spam сносил сообщения и закрывал лид, segment менял лид. Старые кнопки
# на карточке и поддельный callback_data теперь закрыты инвариантом.
RSpec.describe 'staff_test-изоляция: центральный гейт callback-ов' do
  let(:acks) { [] }
  let(:deleted) { [] }
  let(:tg_client) do
    client = instance_double(Telegram::Client)
    allow(client).to receive(:answer_callback_query) do |_id, text: nil, show_alert: false|
      acks << { text: text, alert: show_alert }
      { 'ok' => true }
    end
    allow(client).to receive(:delete_message) { |chat_id:, message_id:| deleted << [chat_id, message_id]; true }
    allow(client).to receive_messages(send_message: { 'message_id' => 1 }, edit_message_text: { 'message_id' => 1 })
    client
  end
  let!(:manager) do
    TelegramUser.create!(tg_user_id: 97_401, tg_username: 'oks', first_name: 'Оксана',
                         role: 'manager', is_manager: true, status: 'active', dm_chat_id: 97_401)
  end
  let!(:agent) do
    TelegramUser.create!(tg_user_id: 97_402, tg_username: 'irina', first_name: 'Ирина',
                         role: 'agent', is_manager: false, status: 'active', dm_chat_id: 97_402)
  end

  let!(:test_lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'show',
                      anchor_topic_key: 'apartments', tg_chat_id: -1_003_779_115_845,
                      anchor_thread_id: 17, anchor_message_id: 900,
                      dispatcher_message_id: 901, deal_mirror_message_id: 902,
                      staff_test: true, metadata: { 'name' => 'Probe Клиент' })
  end

  def run_callback(klass, data)
    cb = { 'id' => 'cb-1', 'data' => data, 'from' => { 'id' => manager.tg_user_id },
           'message' => { 'message_id' => 55, 'chat' => { 'id' => -1_003_779_115_845, 'type' => 'supergroup' } } }
    klass.new(callback_query: cb, tg_user: manager, args: data.split(':').drop(1), client: tg_client).call
  end

  it 'show_assign на test-лиде — ack-отказ, Task и DM не создаются' do
    expect {
      run_callback(Telegram::WorkBot::Callbacks::ShowAssignCallback, "show_assign:#{test_lead.id}:#{agent.id}")
    }.not_to change(Task, :count)
    expect(acks.last[:text]).to include('тестовый')
  end

  it 'spam на test-лиде — ack-отказ, сообщения не сносятся, лид не закрывается' do
    run_callback(Telegram::WorkBot::Callbacks::SpamCallback, "spam:#{test_lead.id}")
    expect(deleted).to be_empty
    expect(test_lead.reload.current_stage).to eq('show')
    expect(acks.last[:text]).to include('тестовый')
  end

  it 'segment на test-лиде — ack-отказ, сегмент не меняется' do
    run_callback(Telegram::WorkBot::Callbacks::SegmentCallback, "segment:#{test_lead.id}:cash")
    expect(test_lead.reload.segment).not_to eq('cash')
    expect(acks.last[:text]).to include('тестовый')
  end

  it 'боевой лид callback-и проходят (гейт не ломает обычную работу)' do
    real = LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'show',
                             anchor_topic_key: 'apartments', tg_chat_id: -1_003_779_115_845,
                             anchor_thread_id: 17, anchor_message_id: 910, assigned_to: agent,
                             segment: 'cold')
    run_callback(Telegram::WorkBot::Callbacks::SegmentCallback, "segment:#{real.id}:cash")
    expect(real.reload.segment).to eq('cash')
    expect(acks.last[:text]).to include('✅')
  end
end
