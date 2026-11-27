# frozen_string_literal: true

require 'rails_helper'

# Issue #277 — мастер редактирования полей лида с карточки дашборда:
# поле → значение следующим сообщением → сохранение в metadata + перерисовка
# карточки. Гоняется через настоящие callback_data, как в engine_spec.
RSpec.describe Telegram::WorkBot::Wizard::LeadEditFlow do
  let(:dms) { [] }
  let(:acks) { [] }
  let(:tg_client) do
    client = instance_double(Telegram::Client)
    allow(client).to receive(:send_message) do |text, **opts|
      dms << { text: text, keyboard: opts.dig(:reply_markup, :inline_keyboard) || [], chat_id: opts[:chat_id] }
      { 'message_id' => 1000 + dms.size }
    end
    allow(client).to receive_messages(edit_message_reply_markup: true, edit_message_text: { 'message_id' => 1 })
    allow(client).to receive(:answer_callback_query) { |_id, text: nil, show_alert: false| acks << [text, show_alert] }
    client
  end

  let!(:manager) do
    TelegramUser.create!(tg_user_id: 120_201, tg_username: 'oks', first_name: 'Оксана',
                         role: 'director', is_manager: true, status: 'active', dm_chat_id: 120_201)
  end
  let!(:agent) do
    TelegramUser.create!(tg_user_id: 120_202, tg_username: 'irina', first_name: 'Ирина',
                         role: 'agent', is_manager: false, status: 'active')
  end
  let!(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'new',
                      anchor_topic_key: 'apartments', tg_chat_id: -1_003_779_115_845,
                      anchor_thread_id: 17, anchor_message_id: 555, assigned_to: agent,
                      metadata: { 'name' => 'Анна Смирнова', 'phone' => '+79001234567' })
  end

  before do
    allow(DispatcherDigestRefreshJob).to receive(:perform_async)
    # Перерисовка якорной карточки в топике — отдельная механика LeadAnnouncer;
    # здесь проверяем только факт вызова, рендер покрыт его спеками.
    allow(Telegram::WorkBot::LeadAnnouncer).to receive(:refresh!)
  end

  def engine(user = manager)
    Telegram::WorkBot::Wizard::Engine.new(tg_user: user, client: tg_client)
  end

  def last_text
    dms.last[:text]
  end

  def press(label, user: manager)
    button = dms.last[:keyboard].flatten.find { |b| b[:text].include?(label) }
    raise "нет кнопки «#{label}» в: #{dms.last[:keyboard].flatten.map { |b| b[:text] }}" unless button

    tap_callback(button[:callback_data], user: user)
  end

  def tap_callback(data, user: manager)
    cb = { 'id' => 'cb1', 'data' => data, 'from' => { 'id' => user.tg_user_id },
           'message' => { 'message_id' => 1, 'chat' => { 'id' => user.tg_user_id, 'type' => 'private' } } }
    Telegram::WorkBot::Callbacks::WizardCallback.new(callback_query: cb, tg_user: user,
                                                     args: data.split(':').drop(1), client: tg_client).call
  end

  def say(text, user: manager)
    engine(user).text(text)
  end

  it 'с карточки: поле → значение → имя сохранено, карточка перерисована' do
    tap_callback("wiz:s:lead_edit:#{lead.id}")
    expect(last_text).to include("Что меняем у лида ##{lead.id}?")

    press('👤 Имя')
    expect(last_text).to include('Пришли новое значение')

    say('Анна Сергеевна')
    expect(lead.reload.metadata['name']).to eq('Анна Сергеевна')
    expect(last_text).to include('обновлено', 'Анна Сергеевна')
    # Финал — перерисованная карточка с действиями, а не голое подтверждение.
    callbacks = dms.last[:keyboard].flatten.map { |b| b[:callback_data] }
    expect(callbacks).to include("dashboard:lead:#{lead.id}:del", "assign:#{lead.id}")
    expect(Telegram::WorkBot::LeadAnnouncer).to have_received(:refresh!).with(lead, client: tg_client)
    expect(manager.reload.pending_action).to be_nil
  end

  it 'телефон нормализуется к +7…' do
    tap_callback("wiz:s:lead_edit:#{lead.id}")
    press('📞 Телефон')
    say('8 (900) 765-43-21')

    expect(lead.reload.metadata['phone']).to eq('+79007654321')
    expect(last_text).to include('+79007654321')
  end

  it 'невалидный телефон — ошибка без сброса шага' do
    tap_callback("wiz:s:lead_edit:#{lead.id}")
    press('📞 Телефон')
    say('123')

    expect(last_text).to include('не похоже на телефон', 'Шаг не сброшен')
    expect(lead.reload.metadata['phone']).to eq('+79001234567')

    say('+7 900 111-22-33')
    expect(lead.reload.metadata['phone']).to eq('+79001112233')
  end

  it 'комментарий сохраняется и виден на перерисованной карточке' do
    tap_callback("wiz:s:lead_edit:#{lead.id}")
    press('💬 Комментарий')
    say('просит перезвонить после 18:00')

    expect(lead.reload.metadata['comment']).to eq('просит перезвонить после 18:00')
    expect(last_text).to include('💬 просит перезвонить после 18:00')
  end

  it 'закрытый лид редактировать можно' do
    lead.update!(current_stage: 'closed_won')
    tap_callback("wiz:s:lead_edit:#{lead.id}")
    press('👤 Имя')
    say('Анна (архив)')

    expect(lead.reload.metadata['name']).to eq('Анна (архив)')
  end

  it 'staff_test-лид — отказ до первого вопроса' do
    lead.update!(staff_test: true)
    tap_callback("wiz:s:lead_edit:#{lead.id}")

    expect(last_text).to include('тестовый (probe)')
    expect(lead.reload.metadata['name']).to eq('Анна Смирнова')
  end

  it 'удалённый лид — отказ до первого вопроса' do
    lead.update!(deleted_at: Time.current)
    tap_callback("wiz:s:lead_edit:#{lead.id}")

    expect(last_text).to include('не найден')
  end

  it 'агент без прав manager — отказ до первого вопроса' do
    tap_callback("wiz:s:lead_edit:#{lead.id}", user: agent)

    expect(last_text).to include('только руководителям')
  end

  # Ревью #280 (раунд 2) — контекст возврата прошит через wizard: финальная
  # карточка после сохранения ведёт «Назад» туда, откуда открыли редактирование.
  describe 'контекст возврата после сохранения' do
    def final_callbacks
      dms.last[:keyboard].flatten.map { |b| b[:callback_data] }
    end

    it 'путь из карточки сотрудника (s<sid>:<page>): назад — в карточку сотрудника' do
      tap_callback("wiz:s:lead_edit:#{lead.id}:s#{agent.id}:2")
      press('👤 Имя')
      say('Анна Сергеевна')

      expect(lead.reload.metadata['name']).to eq('Анна Сергеевна')
      expect(final_callbacks).to include("dashboard:staff:#{agent.id}:2")
      expect(final_callbacks).to include("dashboard:lead:#{lead.id}:s#{agent.id}:2:del")
      expect(final_callbacks).to include("wiz:s:lead_edit:#{lead.id}:s#{agent.id}:2")
    end

    it 'путь из списка лидов (p<page>): назад — на исходную страницу, а не пересчитанную' do
      # 12 лидов: наш — самый старый, на странице 2. Сохранение трогает
      # updated_at и сдвигает его на страницу 1 — вычисленная заново страница
      # была бы неверной, зафиксированная в callback — верна (ревью #280).
      others = Array.new(12) do |i|
        LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'new',
                          anchor_topic_key: 'dispatcher', tg_chat_id: -1_002_000_000_000,
                          metadata: { 'name' => "Клиент #{i}" }).tap do |le|
          le.update_column(:updated_at, (i + 1).minutes.ago) # rubocop:disable Rails/SkipsModelValidations
        end
      end
      lead.update_column(:updated_at, 30.minutes.ago) # rubocop:disable Rails/SkipsModelValidations

      tap_callback("wiz:s:lead_edit:#{lead.id}:p2")
      press('👤 Имя')
      say('Анна Сергеевна')

      expect(final_callbacks).to include('dashboard:leads:p:2')
      expect(final_callbacks).to include("dashboard:lead:#{lead.id}:p2:del")
      expect(final_callbacks).to include("wiz:s:lead_edit:#{lead.id}:p2")
      # Пересчитанная страница была бы 1 — убеждаемся, что она нигде не просочилась.
      expect(final_callbacks).not_to include('dashboard:leads:p:1')
      expect(others.map(&:id)).not_to be_empty
    end

    it 'битый сегмент контекста игнорируется — карточка без origin' do
      tap_callback("wiz:s:lead_edit:#{lead.id}:hax")
      press('👤 Имя')
      say('Анна Сергеевна')

      expect(final_callbacks).to include("dashboard:lead:#{lead.id}:del")
      expect(final_callbacks.grep(/dashboard:staff:/)).to be_empty
    end
  end
end
