# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Commands::Segment do
  let(:tg_client) do
    instance_double(Telegram::Client, send_message: { 'message_id' => 1 }, edit_message_text: { 'message_id' => 1 })
  end
  let(:agent) { TelegramUser.create!(tg_user_id: 111, role: 'agent', first_name: 'A', is_manager: false, status: 'active', dm_chat_id: 111) }
  let!(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'tg_dm', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_123, anchor_message_id: 9000, assigned_to: agent)
  end

  def run(args, msg_overrides = {})
    msg = { 'chat' => { 'id' => 111, 'type' => 'private' }, 'from' => { 'id' => 111 }, 'message_id' => 5,
            'text' => "/segment #{args}" }.merge(msg_overrides)
    described_class.new(message: msg, args: args, tg_user: agent, client: tg_client).send(:handle)
  end

  it '/segment <id> ипотека одобрена — ставит mortgage_approved' do
    run("#{lead.id} ипотека одобрена")
    expect(lead.reload.segment).to eq('mortgage_approved')
    expect(tg_client).to have_received(:send_message).with(a_string_including('🏦 Ипотека одобрена'), anything)
  end

  it 'reply на карточку в группе работает без id' do
    run('наличные', 'chat' => { 'id' => -100_123, 'type' => 'supergroup' }, 'reply_to_message' => { 'message_id' => 9000 })
    expect(lead.reload.segment).to eq('cash')
  end

  it 'без аргумента — показывает клавиатуру выбора, сегмент не меняет' do
    run(lead.id.to_s)
    expect(lead.reload.segment).to be_nil
    expect(tg_client).to have_received(:send_message)
      .with(a_string_including('сегмент'), hash_including(reply_markup: hash_including(:inline_keyboard)))
  end

  it 'неизвестное слово — подсказка со списком' do
    run("#{lead.id} богатый")
    expect(lead.reload.segment).to be_nil
    expect(tg_client).to have_received(:send_message).with(a_string_including('Доступно'), anything)
  end
end
