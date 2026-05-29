# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Commands::Dashboard do
  let!(:director) do
    TelegramUser.create!(tg_user_id: 500_001, tg_username: 'oks', first_name: 'Оксана',
                         role: 'director', is_manager: true, status: 'active', dm_chat_id: 500_001)
  end
  let!(:agent) do
    TelegramUser.create!(tg_user_id: 500_002, tg_username: 'irina', first_name: 'Ирина',
                         role: 'agent', is_manager: false, status: 'active', dm_chat_id: 500_002)
  end

  let(:tg_client) { instance_double(Telegram::Client, send_message: { 'message_id' => 1 }) }

  let(:dm_message) do
    {
      'message_id' => 1, 'from' => { 'id' => director.tg_user_id },
      'chat' => { 'id' => director.tg_user_id, 'type' => 'private' },
      'text' => '/dashboard'
    }
  end

  describe '#call' do
    context 'director' do
      it 'возвращает snapshot со всеми 4 секциями + drill keyboard' do
        described_class.new(message: dm_message, args: '', tg_user: director, client: tg_client).call

        expect(tg_client).to have_received(:send_message).with(
          a_string_matching(/Дашборд АН Виктори/),
          hash_including(
            chat_id: director.tg_user_id,
            parse_mode: 'HTML',
            reply_markup: a_hash_including(:inline_keyboard)
          )
        )
      end

      it 'inline-keyboard содержит 5 drill-кнопок' do
        described_class.new(message: dm_message, args: '', tg_user: director, client: tg_client).call

        expect(tg_client).to have_received(:send_message) do |_text, **kwargs|
          callbacks = kwargs[:reply_markup][:inline_keyboard].flatten.map { |b| b[:callback_data] }
          expect(callbacks).to include('dashboard:drill:leads', 'dashboard:drill:tasks',
                                       'dashboard:drill:staff', 'dashboard:drill:search',
                                       'dashboard:refresh')
        end
      end

      it 'markdown содержит секции «Лиды»/«Задачи»/«Сотрудники»' do
        described_class.new(message: dm_message, args: '', tg_user: director, client: tg_client).call

        expect(tg_client).to have_received(:send_message).with(
          a_string_matching(/Лиды.*Задачи.*Сотрудники/m), anything
        )
      end
    end

    context 'manager (не director)' do
      let!(:manager) do
        TelegramUser.create!(tg_user_id: 500_003, tg_username: 'nick', first_name: 'Николай',
                             role: 'manager', is_manager: true, status: 'active', dm_chat_id: 500_003)
      end

      it 'тоже видит dashboard (manager_only, не director_only)' do
        msg = dm_message.merge('from' => { 'id' => manager.tg_user_id })
        described_class.new(message: msg, args: '', tg_user: manager, client: tg_client).call

        expect(tg_client).to have_received(:send_message).with(
          a_string_matching(/Дашборд АН/), anything
        )
      end
    end

    context 'agent (denied)' do
      it '🚫 manager-only reply, без dashboard' do
        msg = dm_message.merge('from' => { 'id' => agent.tg_user_id })
        described_class.new(message: msg, args: '', tg_user: agent, client: tg_client).call

        expect(tg_client).to have_received(:send_message).with(
          a_string_matching(/Только для руководителей/),
          hash_including(chat_id: agent.tg_user_id)
        )
        expect(tg_client).not_to have_received(:send_message).with(
          a_string_matching(/Дашборд АН/), anything
        )
      end
    end

    context 'unregistered user' do
      it '🚫 «доступна только сотрудникам» reply' do
        msg = {
          'message_id' => 1, 'from' => { 'id' => 999_999 },
          'chat' => { 'id' => 999_999, 'type' => 'private' }, 'text' => '/dashboard'
        }
        described_class.new(message: msg, args: '', tg_user: nil, client: tg_client).call

        expect(tg_client).to have_received(:send_message).with(
          a_string_matching(/только сотрудникам/), anything
        )
      end
    end
  end
end
