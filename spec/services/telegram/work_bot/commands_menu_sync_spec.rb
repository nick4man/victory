# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::CommandsMenuSync do
  let(:client) { instance_double(Telegram::Client, set_my_commands: { 'ok' => true }, delete_my_commands: { 'ok' => true }) }
  let(:sync)   { described_class.new(client: client) }

  describe '#sync_global!' do
    before { sync.sync_global! }

    it 'устанавливает default scope с public-tier (3 команды)' do
      expect(client).to have_received(:set_my_commands).with(
        commands: array_including(
          a_hash_including(command: 'help'),
          a_hash_including(command: 'whoami'),
          a_hash_including(command: 'start')
        ),
        scope: { type: 'default' },
        language_code: 'ru'
      ).at_least(:once)
    end

    it 'устанавливает all_group_chats scope с pipeline-командами' do
      expect(client).to have_received(:set_my_commands).with(
        commands: array_including(
          a_hash_including(command: 'done'),
          a_hash_including(command: 'assign'),
          a_hash_including(command: 'route'),
          a_hash_including(command: 'stage'),
          a_hash_including(command: 'note'),
          a_hash_including(command: 'lead'),
          a_hash_including(command: 'close')
        ),
        scope: { type: 'all_group_chats' },
        language_code: 'ru'
      ).at_least(:once)
    end

    it 'language_code = ru' do
      expect(client).to have_received(:set_my_commands).with(
        hash_including(language_code: 'ru')
      ).at_least(:twice)
    end
  end

  describe '#sync_for_user!' do
    context 'agent (public + staff, ~7 команд)' do
      let(:user) do
        TelegramUser.create!(tg_user_id: 901, tg_username: 'agent1', first_name: 'Агент',
                             dm_chat_id: 901, status: 'active', role: 'agent', is_manager: false)
      end

      before { sync.sync_for_user!(user) }

      it 'устанавливает chat scope с agent-набором' do
        expect(client).to have_received(:set_my_commands) do |kwargs|
          cmds = kwargs[:commands].map { |c| c[:command] }
          expect(cmds).to include('help', 'whoami', 'start', 'done', 'cancel', 'reopen', 'doc')
          expect(cmds).not_to include('promote', 'assign', 'resume_batch')
          expect(kwargs[:scope]).to eq({ type: 'chat', chat_id: 901 })
        end
      end
    end

    context 'manager (+ manager-tier)' do
      let(:user) do
        TelegramUser.create!(tg_user_id: 902, tg_username: 'manager1', first_name: 'Менеджер',
                             dm_chat_id: 902, status: 'active', role: 'manager', is_manager: true)
      end

      before { sync.sync_for_user!(user) }

      it 'включает manager-команды (assign, promote, lead и т.д.)' do
        expect(client).to have_received(:set_my_commands) do |kwargs|
          cmds = kwargs[:commands].map { |c| c[:command] }
          expect(cmds).to include('assign', 'route', 'stage', 'note', 'promote', 'demote', 'link', 'lead', 'deactivate')
          expect(cmds).not_to include('resume_batch') # director-only
        end
      end
    end

    context 'director (полный набор)' do
      let(:user) do
        TelegramUser.create!(tg_user_id: 903, tg_username: 'oks07victory', first_name: 'Оксана',
                             dm_chat_id: 903, status: 'active', role: 'director', is_manager: true)
      end

      before { sync.sync_for_user!(user) }

      it 'включает resume_batch (director-only)' do
        expect(client).to have_received(:set_my_commands) do |kwargs|
          cmds = kwargs[:commands].map { |c| c[:command] }
          expect(cmds).to include('resume_batch')
          expect(cmds).to include('help', 'done', 'assign', 'promote') # тоже cumulative
        end
      end
    end

    context 'inactive user' do
      let(:user) do
        TelegramUser.create!(tg_user_id: 904, tg_username: 'former', first_name: 'Бывший',
                             dm_chat_id: 904, status: 'inactive', role: 'agent')
      end

      it 'удаляет меню (delete_my_commands) вместо set' do
        sync.sync_for_user!(user)
        expect(client).to have_received(:delete_my_commands).with(
          scope: { type: 'chat', chat_id: 904 },
          language_code: 'ru'
        )
        expect(client).not_to have_received(:set_my_commands)
      end
    end

    context 'user без dm_chat_id (не делал /start)' do
      let(:user) do
        TelegramUser.create!(tg_user_id: 905, tg_username: 'lurker', first_name: 'Тихий',
                             status: 'active', role: 'agent')
      end

      it 'возвращает false и не делает API-вызов' do
        expect(sync.sync_for_user!(user)).to be(false)
        expect(client).not_to have_received(:set_my_commands)
        expect(client).not_to have_received(:delete_my_commands)
      end
    end
  end

  describe '#tiers_for' do
    it 'agent → public+staff' do
      u = TelegramUser.new(role: 'agent', is_manager: false)
      expect(sync.tiers_for(u)).to eq(%i[public staff])
    end

    it 'manager → public+staff+manager' do
      u = TelegramUser.new(role: 'manager', is_manager: true)
      expect(sync.tiers_for(u)).to eq(%i[public staff manager])
    end

    it 'director → все 4 tier' do
      u = TelegramUser.new(role: 'director')
      expect(sync.tiers_for(u)).to eq(%i[public staff manager director])
    end

    it 'admin → все 4 tier (как director)' do
      u = TelegramUser.new(role: 'admin')
      expect(sync.tiers_for(u)).to eq(%i[public staff manager director])
    end
  end
end
