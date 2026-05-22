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

    it 'обновляет step и показывает 2 cloud-цели + back (Iter 61: staff target убран — теперь top-level dispose:share)' do
      invoke('photo:dispose:cloud', %w[dispose cloud])
      pa = director.reload.pending_action
      expect(pa['step']).to eq('choose_cloud_target')
      expect(pa['data']['file_id']).to eq('F1')

      expect(tg_client).to have_received(:edit_message_text) do |_text, **kwargs|
        callbacks = kwargs[:reply_markup][:inline_keyboard].flatten.map { |b| b[:callback_data] }
        expect(callbacks).to include('photo:target:general', 'photo:target:lead')
        # staff sub-target удалён в Iter 61 — он стал top-level dispose:share
        expect(callbacks).not_to include('photo:target:staff')
      end
    end
  end

  describe 'dispose:task → step=describe_task (Iter 61 renamed)' do
    before do
      director.set_pending_action!(type: 'photo_disposition', step: 'choose_destination',
                                   data: { file_id: 'F1' })
    end

    it 'устанавливает step describe_task и просит описание' do
      invoke('photo:dispose:task', %w[dispose task])
      expect(director.reload.pending_action['step']).to eq('describe_task')
      expect(tg_client).to have_received(:edit_message_text).with(
        a_string_matching(/Опиши задание/), hash_including(:reply_markup)
      )
    end
  end

  describe 'dispose:staff legacy alias (Iter 60 back-compat → task)' do
    before do
      director.set_pending_action!(type: 'photo_disposition', step: 'choose_destination',
                                   data: { file_id: 'F1' })
    end

    it 'старый callback_data dispose:staff обрабатывается как dispose:task' do
      invoke('photo:dispose:staff', %w[dispose staff])
      expect(director.reload.pending_action['step']).to eq('describe_task')
    end
  end

  describe 'dispose:share → step=choose_share_staff (Iter 61 NEW)' do
    let!(:staff) do
      TelegramUser.create!(tg_user_id: 31_010, tg_username: 'irina', first_name: 'Ирина',
                           role: 'agent', is_manager: false, status: 'active',
                           assignable: true, dm_chat_id: 31_010)
    end

    before do
      director.set_pending_action!(type: 'photo_disposition', step: 'choose_destination',
                                   data: { file_id: 'F1' })
    end

    it 'показывает picker сотрудников + step=choose_share_staff' do
      invoke('photo:dispose:share', %w[dispose share])
      pa = director.reload.pending_action
      expect(pa['step']).to eq('choose_share_staff')

      expect(tg_client).to have_received(:edit_message_text) do |text, **kwargs|
        expect(text).to match(/Кому переслать/)
        callbacks = kwargs[:reply_markup][:inline_keyboard].flatten.map { |b| b[:callback_data] }
        expect(callbacks).to include("photo:share_to:#{staff.id}")
      end
    end
  end

  describe 'share_to:<id> → step=share_caption (Iter 61)' do
    let!(:staff) do
      TelegramUser.create!(tg_user_id: 31_020, tg_username: 'masha', first_name: 'Маша',
                           role: 'agent', is_manager: false, status: 'active',
                           assignable: true, dm_chat_id: 31_020)
    end

    before do
      director.set_pending_action!(type: 'photo_disposition', step: 'choose_share_staff',
                                   data: { file_id: 'F1' })
    end

    it 'сохраняет target_staff_id + step=share_caption + просит подпись' do
      invoke("photo:share_to:#{staff.id}", ['share_to', staff.id.to_s])
      pa = director.reload.pending_action
      expect(pa['step']).to eq('share_caption')
      expect(pa['data']['target_staff_id']).to eq(staff.id)

      expect(tg_client).to have_received(:edit_message_text).with(
        a_string_matching(/Получатель.*#{staff.tg_username}.*подпись.*\/skip/m),
        hash_including(:reply_markup)
      )
    end
  end
end
