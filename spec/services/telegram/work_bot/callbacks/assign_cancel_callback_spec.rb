# frozen_string_literal: true

require 'rails_helper'

# [✖️ Отмена] в picker-сообщении назначения. Вторая половина пары к
# AssignCallback: тот кладёт id picker-сообщения в metadata, этот его оттуда
# забирает и чистит. Если ключ не убрать — следующий picker перезапишет его
# своим id, а старое сообщение останется висеть в топике навсегда.
RSpec.describe Telegram::WorkBot::Callbacks::AssignCancelCallback do
  let(:acks) { [] }
  let(:deleted) { [] }
  let(:tg_client) do
    client = instance_double(Telegram::Client)
    allow(client).to receive(:answer_callback_query) do |_id, text: nil, show_alert: false|
      acks << { text: text, alert: show_alert }
      { 'ok' => true }
    end
    allow(client).to receive(:delete_message) do |chat_id:, message_id:|
      deleted << { chat_id: chat_id, message_id: message_id }
      true
    end
    client
  end

  let!(:manager) do
    TelegramUser.create!(tg_user_id: 97_301, tg_username: 'oks', first_name: 'Оксана',
                         role: 'manager', is_manager: true, status: 'active', dm_chat_id: 97_301)
  end
  let!(:agent) do
    TelegramUser.create!(tg_user_id: 97_302, tg_username: 'irina', first_name: 'Ирина',
                         role: 'agent', is_manager: false, status: 'active', dm_chat_id: 97_302)
  end

  let!(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'new',
                      anchor_topic_key: 'apartments', tg_chat_id: -1_003_779_115_845,
                      anchor_thread_id: 17, anchor_message_id: 800,
                      metadata: { 'assign_picker_message_id' => 8008 })
  end

  def run(user: manager)
    cb = { 'id' => 'cb-4', 'data' => "assign_cancel:#{lead.id}",
           'from' => { 'id' => user.tg_user_id },
           'message' => { 'message_id' => 8008, 'message_thread_id' => 17,
                          'chat' => { 'id' => -1_003_779_115_845, 'type' => 'supergroup' } } }
    described_class.new(callback_query: cb, tg_user: user, args: [lead.id.to_s],
                        client: tg_client).call
  end

  it 'удаляет picker-сообщение в чате лида' do
    run
    expect(deleted).to eq([{ chat_id: lead.tg_chat_id, message_id: 8008 }])
  end

  it 'убирает ключ из metadata, не затирая остальное' do
    lead.update!(metadata: lead.metadata.merge('name' => 'Клиент'))
    run
    expect(lead.reload.metadata).not_to have_key('assign_picker_message_id')
    expect(lead.reload.metadata['name']).to eq('Клиент')
  end

  it 'если picker уже удалён — Telegram-ошибку глотает и всё равно отвечает' do
    allow(tg_client).to receive(:delete_message).and_raise(Telegram::Client::Error, 'message to delete not found')
    expect { run }.not_to raise_error
    expect(lead.reload.metadata).not_to have_key('assign_picker_message_id')
    expect(acks.last[:text]).to eq('Отменено')
  end

  it 'без сохранённого picker_id ничего не удаляет, но кнопку отпускает' do
    lead.update!(metadata: {})
    run
    expect(deleted).to be_empty
    expect(acks.last[:text]).to eq('Отменено')
  end

  it 'агенту недоступна' do
    run(user: agent)
    expect(deleted).to be_empty
    expect(acks.last[:text]).to include('руководителей')
  end
end
