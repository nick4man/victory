# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Commands::Bargain do
  let(:tg_client) { instance_double(Telegram::Client, send_message: { 'message_id' => 1 }) }
  let(:agent)     { TelegramUser.create!(tg_user_id: 111, role: 'agent', first_name: 'Ирина', status: 'active', dm_chat_id: 111) }
  let!(:director) { TelegramUser.create!(tg_user_id: 333, role: 'director', first_name: 'Оксана', status: 'active', dm_chat_id: 333) }
  let(:property)  { create(:property, address: 'Рязань, ул. Есенина, 12', price: 5_500_000) }
  let!(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'tg_dm', current_stage: 'show', anchor_topic_key: 'apartments',
                      tg_chat_id: -100_1, anchor_thread_id: 17, anchor_message_id: 900, assigned_to: agent,
                      segment: 'cash', property: property, metadata: { 'name' => 'Анна' })
  end

  before do
    ShowReport.create!(lead_event: lead, property: property, conducted_by: agent, reported_by: agent, conducted_at: 1.day.ago,
                       source: 'voice', status: 'confirmed', objections: ['маленькая кухня'])
  end

  def run(args)
    msg = { 'chat' => { 'id' => 111, 'type' => 'private' }, 'from' => { 'id' => 111 }, 'message_id' => 5, 'text' => "/bargain #{args}" }
    described_class.new(message: msg, args: args, tg_user: agent, client: tg_client).send(:handle)
  end

  it 'руководитель получает карточку: объект, цена, названная цена, сегмент, показы, возражения' do
    run("#{lead.id} 5,2 млн")
    expect(tg_client).to have_received(:send_message).with(
      a_string_including('Торг на объекте', 'Есенина', '5 500 000', '5 200 000', 'Наличные', '1 показ', 'маленькая кухня', 'Ирина'),
      hash_including(chat_id: 333)
    )
  end

  it 'агенту — подтверждение «звони»; в metadata — история' do
    run("#{lead.id} 5200000")
    expect(tg_client).to have_received(:send_message).with(a_string_including('звони'), hash_including(chat_id: 111))
    entry = lead.reload.metadata['bargain_requests'].last
    expect(entry['price']).to eq(5_200_000)
    expect(entry['by']).to eq(agent.mention)
  end

  it 'цена не распознана → формат' do
    run("#{lead.id} дорого")
    expect(tg_client).to have_received(:send_message).with(a_string_including('Формат'), anything)
    expect(tg_client).not_to have_received(:send_message).with(anything, hash_including(chat_id: 333))
  end

  it 'директор с заблокированным ботом не ломает рассылку остальным' do
    admin = TelegramUser.create!(tg_user_id: 444, role: 'director', first_name: 'Зам', status: 'active', dm_chat_id: 444)
    allow(tg_client).to receive(:send_message).with(anything, hash_including(chat_id: 333)).and_raise(Telegram::Client::Error, 'bot was blocked')
    run("#{lead.id} 5200000")
    expect(tg_client).to have_received(:send_message).with(anything, hash_including(chat_id: admin.dm_chat_id))
  end
end
