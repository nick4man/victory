# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Router do
  let(:sent) { [] }
  let(:tg_client) do
    client = instance_double(Telegram::Client)
    allow(client).to receive(:send_message) { |text, **_opts| sent << text; { 'message_id' => 1 } }
    client
  end

  def dispatch(text, from_id:)
    msg = { 'from' => { 'id' => from_id }, 'chat' => { 'id' => from_id, 'type' => 'private' },
            'message_id' => 11, 'text' => text }
    described_class.new(msg, client: tg_client).call
  end

  it 'клиенту (нет строки в telegram_users) не показывает подсказку про /whoami' do
    expect(dispatch('/квартира', from_id: 999)).to eq(:client_hint)
    expect(sent.join).not_to include('/whoami')
  end

  it 'сотруднику на нераспознанную команду отвечает как раньше' do
    TelegramUser.create!(tg_user_id: 777, role: 'agent', first_name: 'A',
                         is_manager: false, status: 'active', dm_chat_id: 777)
    expect(dispatch('/нетакой', from_id: 777)).to eq(:unknown_command)
    expect(sent.join).to include('/whoami')
  end

  it 'экранирует команду в ответе — /<b от клиента не роняет sendMessage' do
    TelegramUser.create!(tg_user_id: 778, role: 'agent', first_name: 'B',
                         is_manager: false, status: 'active', dm_chat_id: 778)
    dispatch('/<b', from_id: 778)
    expect(sent.join).to include('&lt;b')
  end
end
