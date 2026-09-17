# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Commands::Stage do
  let(:tg_client) do
    instance_double(Telegram::Client, send_message: { 'message_id' => 1 }, edit_message_text: { 'message_id' => 1 })
  end
  let(:agent) { TelegramUser.create!(tg_user_id: 111, role: 'agent', first_name: 'A', is_manager: false, status: 'active') }
  let!(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'tg_dm', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_123, anchor_message_id: 9000, assigned_to: agent)
  end

  def run(args)
    msg = { 'chat' => { 'id' => -100_123, 'type' => 'supergroup' }, 'from' => { 'id' => 111 }, 'message_id' => 5,
            'reply_to_message' => { 'message_id' => 9000 }, 'text' => "/stage #{args}" }
    described_class.new(message: msg, args: args, tg_user: agent, client: tg_client).send(:handle)
  end

  it '/stage показ без сегмента → переход + клавиатура сегмента' do
    run('показ')
    expect(lead.reload.current_stage).to eq('show')
    expect(tg_client).to have_received(:send_message)
      .with(a_string_including('сегмент'), hash_including(reply_markup: hash_including(:inline_keyboard)))
  end

  it '/stage показ с сегментом → без нуджа' do
    lead.update!(segment: 'cold')
    run('показ')
    expect(tg_client).to have_received(:send_message).once
  end

  it 'неизвестная стадия → подсказка' do
    run('лунная')
    expect(tg_client).to have_received(:send_message).with(a_string_including('Неизвестная стадия'), anything)
  end
end
