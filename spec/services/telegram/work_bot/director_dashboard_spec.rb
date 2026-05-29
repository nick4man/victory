# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::DirectorDashboard do
  let!(:director) do
    TelegramUser.create!(tg_user_id: 90_001, tg_username: 'dir', first_name: 'Dir',
                         role: 'director', is_manager: true, status: 'active')
  end

  describe '#call' do
    it 'возвращает Result с markdown + keyboard' do
      result = described_class.new(tg_user: director).call
      expect(result.markdown).to be_a(String)
      expect(result.markdown).to include('Дашборд АН Виктори')
      expect(result.keyboard).to have_key(:inline_keyboard)
    end

    it 'inline-keyboard содержит drill-кнопки' do
      result = described_class.new(tg_user: director).call
      callbacks = result.keyboard[:inline_keyboard].flatten.map { |b| b[:callback_data] }
      expect(callbacks).to include('dashboard:drill:leads', 'dashboard:drill:tasks',
                                   'dashboard:drill:staff', 'dashboard:drill:search',
                                   'dashboard:refresh')
    end

    it 'markdown содержит секции «Лиды» и «Задачи»' do
      result = described_class.new(tg_user: director).call
      expect(result.markdown).to include('🎯 <b>Лиды</b>')
      expect(result.markdown).to include('✅ <b>Задачи</b>')
    end
  end
end
