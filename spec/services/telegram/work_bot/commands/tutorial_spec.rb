# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Commands::Tutorial do
  let(:tg_client) { instance_double(Telegram::Client, send_message: { 'message_id' => 1 }) }
  let(:agent) do
    TelegramUser.create!(tg_user_id: 142_001, tg_username: 'irina', first_name: 'Ирина',
                         role: 'agent', is_manager: false, status: 'active', dm_chat_id: 142_001)
  end
  let(:group_chat_id) { -1_003_779_115_845 }

  def dm_message
    { 'message_id' => 5, 'chat' => { 'id' => agent.dm_chat_id, 'type' => 'private' },
      'from' => { 'id' => agent.tg_user_id } }
  end

  def group_message
    { 'message_id' => 7, 'message_thread_id' => 12,
      'chat' => { 'id' => group_chat_id, 'type' => 'supergroup' },
      'from' => { 'id' => agent.tg_user_id } }
  end

  def run(message, tg_user: agent)
    described_class.new(message: message, args: '', tg_user: tg_user, client: tg_client).call
  end

  describe 'в личке' do
    it 'шлёт карточку первого урока с inline-кнопками' do
      run(dm_message)

      expect(tg_client).to have_received(:send_message).once.with(
        a_string_including('Урок 1 из'),
        hash_including(chat_id: agent.dm_chat_id,
                       parse_mode: 'HTML',
                       reply_markup: hash_including(:inline_keyboard))
      )
    end
  end

  describe 'в рабочей группе' do
    it 'карточку отправляет в личку, а в группу — только строку-указатель' do
      run(group_message)

      expect(tg_client).to have_received(:send_message).with(
        a_string_including('Урок 1 из'), hash_including(chat_id: agent.dm_chat_id)
      )
      expect(tg_client).to have_received(:send_message).with(
        a_string_including('в личку'), hash_including(chat_id: group_chat_id)
      )
    end

    it 'не показывает кнопки обучения в общем чате' do
      run(group_message)

      expect(tg_client).not_to have_received(:send_message).with(
        anything, hash_including(chat_id: group_chat_id, reply_markup: hash_including(:inline_keyboard))
      )
    end

    it 'если личка недоступна — подсказывает открыть её, но карточку в группу не выкладывает' do
      allow(tg_client).to receive(:send_message) do |text, **|
        raise Telegram::Client::Error, 'Forbidden: bot was blocked by the user' if text.include?('Урок 1 из')

        { 'message_id' => 1 }
      end

      run(group_message)

      expect(tg_client).to have_received(:send_message).with(
        a_string_including('Напиши мне в личные сообщения'), hash_including(chat_id: group_chat_id)
      )
    end
  end

  describe 'незарегистрированный отправитель' do
    it 'получает отказ от гейта Commands::Base, а не урок' do
      run(dm_message, tg_user: nil)

      expect(tg_client).to have_received(:send_message).once.with(
        a_string_including('только сотрудникам АН'), anything
      )
    end
  end
end
