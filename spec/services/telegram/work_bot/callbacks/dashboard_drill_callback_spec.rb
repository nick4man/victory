# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Callbacks::DashboardDrillCallback do
  let!(:director) do
    TelegramUser.create!(tg_user_id: 120_001, tg_username: 'oks', first_name: 'Оксана',
                         role: 'director', is_manager: true, status: 'active', dm_chat_id: 120_001)
  end

  let(:tg_client) do
    instance_double(
      Telegram::Client,
      edit_message_text: { 'message_id' => 100 },
      answer_callback_query: { 'ok' => true }
    )
  end

  def build_cb(data)
    {
      'id' => 'cb_id_1',
      'from' => { 'id' => director.tg_user_id },
      'data' => data,
      'message' => {
        'message_id' => 555,
        'chat' => { 'id' => director.tg_user_id, 'type' => 'private' }
      }
    }
  end

  def invoke(data, args)
    described_class.new(callback_query: build_cb(data), tg_user: director, args: args, client: tg_client).call
  end

  describe 'drill:leads' do
    it 'edit_message_text с детальным leads breakdown + back keyboard' do
      invoke('dashboard:drill:leads', %w[drill leads])
      expect(tg_client).to have_received(:edit_message_text).with(
        a_string_matching(/Лиды.*детально/m),
        hash_including(reply_markup: a_hash_including(:inline_keyboard))
      )
    end
  end

  describe 'drill:tasks' do
    it 'edit_message_text с tasks breakdown' do
      invoke('dashboard:drill:tasks', %w[drill tasks])
      expect(tg_client).to have_received(:edit_message_text).with(
        a_string_matching(/Задачи.*детально/m),
        hash_including(:reply_markup)
      )
    end
  end

  describe 'drill:staff' do
    it 'edit_message_text с per-staff cards' do
      invoke('dashboard:drill:staff', %w[drill staff])
      expect(tg_client).to have_received(:edit_message_text).with(
        a_string_matching(/Сотрудники.*детально/m),
        hash_including(:reply_markup)
      )
    end
  end

  describe 'drill:search' do
    it 'edit_message_text с prompt про free-form search' do
      invoke('dashboard:drill:search', %w[drill search])
      expect(tg_client).to have_received(:edit_message_text).with(
        a_string_matching(/Поиск.*найди сообщения/m),
        hash_including(:reply_markup)
      )
    end
  end

  describe 'refresh' do
    it 'пересчитывает main dashboard' do
      invoke('dashboard:refresh', ['refresh'])
      expect(tg_client).to have_received(:edit_message_text).with(
        a_string_matching(/Дашборд АН Виктори/),
        hash_including(:reply_markup)
      )
    end
  end

  describe 'unknown drill target' do
    it 'alert' do
      invoke('dashboard:drill:unknown', %w[drill unknown])
      expect(tg_client).to have_received(:answer_callback_query).with(
        'cb_id_1', text: a_string_matching(/Неизвестная секция/), show_alert: true
      )
    end
  end
end
