# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Callbacks::PhotoDispositionCallback do
  let!(:director) do
    TelegramUser.create!(tg_user_id: 31_001, tg_username: 'oks07victory', first_name: 'Оксана',
                         role: 'director', is_manager: true, status: 'active', dm_chat_id: 31_001)
  end

  let(:tg_client) do
    instance_double(
      Telegram::Client,
      send_message: { 'message_id' => 100 },
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

  describe 'pending_action не установлен' do
    it 'alert «сессия истекла»' do
      director.clear_pending_action!
      invoke('photo:dispose:cloud', %w[dispose cloud])
      expect(tg_client).to have_received(:answer_callback_query).with(
        'cb_id_1', text: a_string_matching(/Сессия фото истекла/), show_alert: true
      )
    end
  end

  describe 'dispose:cancel' do
    before do
      director.set_pending_action!(type: 'photo_disposition', step: 'choose_destination',
                                   data: { file_id: 'F1' })
    end

    it 'clear_pending_action + edit message + ack' do
      invoke('photo:dispose:cancel', %w[dispose cancel])
      expect(director.reload.dm_pending_action).to eq({})
      expect(tg_client).to have_received(:edit_message_text).with(
        a_string_matching(/Отменено/), hash_including(chat_id: director.tg_user_id, message_id: 555)
      )
      expect(tg_client).to have_received(:answer_callback_query)
    end
  end

  describe 'dispose:cloud → step=choose_cloud_target' do
    before do
      director.set_pending_action!(type: 'photo_disposition', step: 'choose_destination',
                                   data: { file_id: 'F1' })
    end

    it 'обновляет step и показывает 3 кнопки целей' do
      invoke('photo:dispose:cloud', %w[dispose cloud])
      pa = director.reload.pending_action
      expect(pa['step']).to eq('choose_cloud_target')
      expect(pa['data']['file_id']).to eq('F1')

      expect(tg_client).to have_received(:edit_message_text) do |_text, **kwargs|
        callbacks = kwargs[:reply_markup][:inline_keyboard].flatten.map { |b| b[:callback_data] }
        expect(callbacks).to include('photo:target:general', 'photo:target:lead', 'photo:target:staff')
      end
    end
  end

  describe 'dispose:staff → step=describe_task' do
    before do
      director.set_pending_action!(type: 'photo_disposition', step: 'choose_destination',
                                   data: { file_id: 'F1' })
    end

    it 'устанавливает step describe_task и просит описание' do
      invoke('photo:dispose:staff', %w[dispose staff])
      expect(director.reload.pending_action['step']).to eq('describe_task')
      expect(tg_client).to have_received(:edit_message_text).with(
        a_string_matching(/Опиши задание/), hash_including(:reply_markup)
      )
    end
  end
end
