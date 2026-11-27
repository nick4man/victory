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
    it 'edit_message_text с постраничным списком лидов (страница 1) + back keyboard' do
      invoke('dashboard:drill:leads', %w[drill leads])
      expect(tg_client).to have_received(:edit_message_text).with(
        a_string_matching(/Лиды.*детально.*страница 1\//m),
        hash_including(reply_markup: a_hash_including(:inline_keyboard))
      )
    end
  end

  describe 'leads:p:<page>' do
    let!(:leads) do
      Array.new(12) do |i|
        LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'new',
                          anchor_topic_key: 'dispatcher', tg_chat_id: -1_002_000_000_000,
                          metadata: { 'name' => "Клиент #{i}" })
      end
    end

    it 'рендерит запрошенную страницу списка лидов' do
      invoke('dashboard:leads:p:2', %w[leads p 2])
      expect(tg_client).to have_received(:edit_message_text).with(
        a_string_matching(/страница 2\/2/m),
        hash_including(reply_markup: a_hash_including(:inline_keyboard))
      )
    end

    it 'повторный тап по той же странице рендерит идентичный список' do
      texts = []
      keyboards = []
      allow(tg_client).to receive(:edit_message_text) do |text, opts|
        texts << text
        keyboards << opts[:reply_markup]
      end

      invoke('dashboard:leads:p:1', %w[leads p 1])
      invoke('dashboard:leads:p:1', %w[leads p 1])

      expect(texts.size).to eq(2)
      expect(texts[0]).to eq(texts[1])
      expect(keyboards[0]).to eq(keyboards[1])
    end
  end

  describe 'staff:p:<page>' do
    it 'рендерит страницу списка сотрудников' do
      invoke('dashboard:staff:p:1', %w[staff p 1])
      expect(tg_client).to have_received(:edit_message_text).with(
        a_string_matching(/Сотрудники.*детально.*страница 1\//m),
        hash_including(reply_markup: a_hash_including(:inline_keyboard))
      )
    end
  end

  describe 'staff:<id> — карточка сотрудника (issue #277)' do
    let!(:agent) do
      TelegramUser.create!(tg_user_id: 120_777, tg_username: 'agent277', first_name: 'Агент',
                           role: 'agent', status: 'active', assignable: true)
    end

    it 'рендерит карточку сотрудника (DashboardStaffCallback)' do
      invoke("dashboard:staff:#{agent.id}", ['staff', agent.id.to_s])
      expect(tg_client).to have_received(:edit_message_text).with(
        a_string_matching(/👤.*Агент/m),
        hash_including(reply_markup: a_hash_including(:inline_keyboard))
      )
    end

    it 'несуществующий id — вежливый отказ без изменений' do
      invoke('dashboard:staff:999999', %w[staff 999999])
      expect(tg_client).not_to have_received(:edit_message_text)
      expect(tg_client).to have_received(:answer_callback_query).with(
        'cb_id_1', text: a_string_matching(/не найден/), show_alert: true
      )
    end
  end

  describe 'lead:<id> — карточка лида (issue #277)' do
    let!(:lead) do
      LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'new',
                        anchor_topic_key: 'dispatcher', tg_chat_id: -1_002_000_000_000,
                        metadata: { 'name' => 'Анна Смирнова', 'phone' => '+79001234567' })
    end

    it 'тап по лиду рендерит карточку с полями и действиями' do
      invoke("dashboard:lead:#{lead.id}", %w[lead] + [lead.id.to_s])
      expect(tg_client).to have_received(:edit_message_text).with(
        a_string_matching(/Лид ##{lead.id}.*Анна Смирнова/m),
        hash_including(reply_markup: a_hash_including(:inline_keyboard))
      )
    end

    it 'del без yes — экран подтверждения, лид не тронут' do
      invoke("dashboard:lead:#{lead.id}:del", %w[lead] + [lead.id.to_s, 'del'])
      expect(tg_client).to have_received(:edit_message_text).with(
        a_string_matching(/Удалить лид ##{lead.id}\?/m),
        hash_including(reply_markup: a_hash_including(:inline_keyboard))
      )
      expect(lead.reload.deleted_at).to be_nil
    end

    it 'del:yes — soft-delete лида' do
      invoke("dashboard:lead:#{lead.id}:del:yes", %w[lead] + [lead.id.to_s, 'del', 'yes'])
      expect(lead.reload.deleted_at).to be_present
      expect(tg_client).to have_received(:edit_message_text).with(
        a_string_matching(/Лид ##{lead.id} удалён/m),
        hash_including(reply_markup: a_hash_including(:inline_keyboard))
      )
    end

    it 'cancel с экрана confirm возвращает карточку' do
      invoke("dashboard:lead:#{lead.id}", %w[lead] + [lead.id.to_s])
      expect(tg_client).to have_received(:edit_message_text).with(
        a_string_matching(/Лид ##{lead.id}/m),
        hash_including(reply_markup: a_hash_including(:inline_keyboard))
      )
      expect(lead.reload.deleted_at).to be_nil
    end

    it 'несуществующий лид — alert без edit' do
      invoke('dashboard:lead:999999', %w[lead 999999])
      expect(tg_client).not_to have_received(:edit_message_text)
      expect(tg_client).to have_received(:answer_callback_query).with(
        'cb_id_1', text: a_string_matching(/не найден/), show_alert: true
      )
    end

    it 'нечисловой id — alert' do
      invoke('dashboard:lead:abc', %w[lead abc])
      expect(tg_client).not_to have_received(:edit_message_text)
      expect(tg_client).to have_received(:answer_callback_query).with(
        'cb_id_1', text: a_string_matching(/Неизвестный шаг/), show_alert: true
      )
    end

    it 'staff_test-лид — отказ (issue #214)' do
      lead.update!(staff_test: true)
      invoke("dashboard:lead:#{lead.id}", %w[lead] + [lead.id.to_s])
      expect(tg_client).not_to have_received(:edit_message_text)
      expect(tg_client).to have_received(:answer_callback_query).with(
        'cb_id_1', text: a_string_matching(/тестовый \(probe\)/), show_alert: true
      )
    end

    it 'удалённый лид — alert «не найден»' do
      lead.update!(deleted_at: Time.current)
      invoke("dashboard:lead:#{lead.id}", %w[lead] + [lead.id.to_s])
      expect(tg_client).not_to have_received(:edit_message_text)
      expect(tg_client).to have_received(:answer_callback_query).with(
        'cb_id_1', text: a_string_matching(/не найден/), show_alert: true
      )
    end
  end

  describe 'drill:staff' do
    it 'edit_message_text со списком сотрудников (страница 1)' do
      invoke('dashboard:drill:staff', %w[drill staff])
      expect(tg_client).to have_received(:edit_message_text).with(
        a_string_matching(/Сотрудники.*детально/m),
        hash_including(:reply_markup)
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

  describe 'back' do
    it 'возвращает main dashboard' do
      invoke('dashboard:back', ['back'])
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
