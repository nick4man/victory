# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::CheatsheetRenderer do
  let(:director) do
    TelegramUser.create!(tg_user_id: 130_001, tg_username: 'oks', first_name: 'Оксана',
                         role: 'director', is_manager: true, status: 'active', dm_chat_id: 130_001)
  end
  let(:manager) do
    TelegramUser.create!(tg_user_id: 130_002, tg_username: 'nick', first_name: 'Николай',
                         role: 'manager', is_manager: true, status: 'active', dm_chat_id: 130_002)
  end
  let(:agent) do
    TelegramUser.create!(tg_user_id: 130_003, tg_username: 'irina', first_name: 'Ирина',
                         role: 'agent', is_manager: false, status: 'active', dm_chat_id: 130_003)
  end

  describe '.call для director' do
    let(:md) { described_class.call(tg_user: director) }

    it 'header показывает role=director' do
      expect(md).to include('Cheat-sheet @anvictorybot · director')
    end

    it 'включает все секции (panel/search/actions/photo/voice/digest)' do
      expect(md).to include('📊 <b>Панель управления</b>')
      expect(md).to include('🔍 <b>Поиск')
      expect(md).to include('⚡ <b>Действия')
      expect(md).to include('📷 <b>Фото в DM</b>')
      expect(md).to include('🎙 <b>Голос в DM</b>') # director-only (can_voice_distribute)
      expect(md).to include('📅 <b>Автоматически приходит в DM</b>') # director-only digest
    end

    it 'инклюдит примеры команд с lead_id для DM' do
      expect(md).to include('/assign 87 @irina')
      expect(md).to include('/route 87 apartments')
      expect(md).to include('/close 87 выиграно')
    end

    it 'инклюдит free-form search examples' do
      expect(md).to include('Канищево')
      expect(md).to include('задачи overdue')
      expect(md).to include('топ-performer')
    end

    it 'предлагает закрепить сообщение (long-press → Pin)' do
      expect(md).to include('Закрепи это сообщение')
    end
  end

  describe '.call для manager (не director)' do
    let(:md) { described_class.call(tg_user: manager) }

    it 'header показывает role=manager' do
      expect(md).to include('· manager</b>')
    end

    it 'видит panel/search/actions но НЕ voice и НЕ digest' do
      expect(md).to include('📊 <b>Панель управления</b>')
      expect(md).to include('🔍 <b>Поиск')
      expect(md).to include('⚡ <b>Действия')
      expect(md).not_to include('🎙 <b>Голос в DM</b>')
      expect(md).not_to include('📅 <b>Автоматически приходит в DM</b>')
    end
  end

  describe '.call для agent' do
    let(:md) { described_class.call(tg_user: agent) }

    it 'header показывает role=agent' do
      expect(md).to include('· agent</b>')
    end

    it 'видит ТОЛЬКО photo + footer (без panel/search/actions/voice/digest)' do
      expect(md).not_to include('Панель управления')
      expect(md).not_to include('Поиск')
      expect(md).not_to include('Действия')
      expect(md).not_to include('Голос в DM')
      expect(md).not_to include('Автоматически приходит')
      expect(md).to include('📷 <b>Фото в DM</b>')
    end
  end

  describe 'message size (TG limit 4096)' do
    it 'director-cheatsheet < 4000 chars (запас)' do
      md = described_class.call(tg_user: director)
      expect(md.size).to be < 4000
    end
  end
end
