# frozen_string_literal: true

require 'rails_helper'

# Issue #277 — сквозной сценарий drill-down навигации дашборда через боевой
# колбэк-роутинг (DashboardDrillCallback): список → карточка → действие →
# «Назад» на ту же страницу списка, а не в начало. Каждый «тап» — callback_data,
# извлечённый из реально отрендеренной клавиатуры предыдущего шага: проверяется
# контракт кнопок целиком, а не отдельные рендеры по частям.
RSpec.describe 'Dashboard drill-down e2e (issue #277)' do
  let(:edits) { [] }
  let(:tg_client) do
    client = instance_double(Telegram::Client, answer_callback_query: { 'ok' => true })
    allow(client).to receive(:edit_message_text) do |text, opts|
      edits << { text: text, keyboard: opts[:reply_markup] }
      { 'message_id' => 100 }
    end
    client
  end

  let!(:director) do
    TelegramUser.create!(tg_user_id: 170_001, tg_username: 'dir277e', first_name: 'Дира',
                         role: 'director', is_manager: true, status: 'active', dm_chat_id: 170_001)
  end
  let!(:admin) do
    TelegramUser.create!(tg_user_id: 170_002, tg_username: 'root277e', first_name: 'Рут',
                         role: 'admin', is_manager: true, status: 'active', dm_chat_id: 170_002)
  end

  def tap(data, viewer:)
    cb = { 'id' => 'cb_e2e', 'data' => data, 'from' => { 'id' => viewer.tg_user_id },
           'message' => { 'message_id' => 555, 'chat' => { 'id' => viewer.tg_user_id, 'type' => 'private' } } }
    Telegram::WorkBot::Callbacks::DashboardDrillCallback.new(
      callback_query: cb, tg_user: viewer, args: data.split(':').drop(1), client: tg_client
    ).call
  end

  def last_text
    edits.last[:text]
  end

  def last_buttons
    edits.last[:keyboard][:inline_keyboard].flatten
  end

  def button(label)
    last_buttons.find { |b| b[:text].include?(label) }&.fetch(:callback_data)
  end

  def row_callback(pattern)
    last_buttons.map { |b| b[:callback_data] }.grep(pattern).first
  end

  describe 'лиды: список → карточка → удаление с confirm → назад' do
    let!(:leads) do
      Array.new(20) do |i|
        LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'new',
                          anchor_topic_key: 'dispatcher', tg_chat_id: -1_002_000_000_000,
                          metadata: { 'name' => "Клиент #{i}" })
      end
    end

    def open_second_leads_page
      tap('dashboard:drill:leads', viewer: director) # сводка → страница 1
      tap(button('▶️'), viewer: director)            # навигация → страница 2
    end

    it 'карточка со страницы 2: «Назад» и confirm удаления ссылаются на неё же' do
      open_second_leads_page
      tap(row_callback(/\Adashboard:lead:\d+\z/), viewer: director)
      expect(button('⬅️ Назад')).to eq('dashboard:leads:p:2')

      tap(button('🗑 Удалить'), viewer: director)
      expect(last_text).to include('Удалить лид #')
      expect(button('✅ Да, удалить')).to end_with(':del:yes')
      expect(LeadEvent.unscoped.where(deleted_at: nil).count).to eq(20)
    end

    it 'del:yes → soft-delete; «К списку лидов» рендерит страницу 2 без удалённого' do
      open_second_leads_page
      page2_ids = last_buttons.filter_map { |b| b[:callback_data][/\Adashboard:lead:(\d+)\z/, 1]&.to_i }
      lead_id = page2_ids.first
      tap("dashboard:lead:#{lead_id}", viewer: director)
      tap(button('🗑 Удалить'), viewer: director)
      tap(button('✅ Да, удалить'), viewer: director)
      expect(button('⬅️ К списку лидов')).to eq('dashboard:leads:p:2')

      tap('dashboard:leads:p:2', viewer: director)
      callbacks = last_buttons.map { |b| b[:callback_data] }
      expect(last_text).to include('страница 2/3')
      expect(callbacks).to include(*page2_ids.excluding(lead_id).map { |id| "dashboard:lead:#{id}" })
      expect(callbacks).not_to include("dashboard:lead:#{lead_id}")
      expect(LeadEvent.find_by(id: lead_id)).to be_nil
    end
  end

  describe 'сотрудники: список → карточка → смена роли (admin) → назад' do
    let!(:agents) do
      Array.new(10) do |i|
        TelegramUser.create!(tg_user_id: 171_000 + i, tg_username: "agent277e#{i}", first_name: "Агент#{i}",
                             role: 'agent', status: 'active', assignable: true)
      end
    end

    it 'карточка со страницы 2: edit → setrole → «Назад» на страницу 2, сотрудник в списке' do
      tap('dashboard:staff:p:2', viewer: admin)
      staff_id = row_callback(/\Adashboard:staff:\d+:2\z/).split(':')[2].to_i
      tap("dashboard:staff:#{staff_id}:2", viewer: admin)
      expect(button('⬅️ Назад')).to eq('dashboard:staff:p:2')

      tap(button('✏️ Редактировать'), viewer: admin)
      expect(button('⬅️ К карточке')).to eq("dashboard:staff:#{staff_id}:2")
      tap(button('🔁 Роль'), viewer: admin)
      tap(button('руководитель'), viewer: admin)
      expect(TelegramUser.find(staff_id).role).to eq('manager')

      tap(button('⬅️ К карточке'), viewer: admin)
      tap(button('⬅️ Назад'), viewer: admin)
      expect(last_text).to include('страница 2/2')
      expect(last_buttons.map { |b| b[:callback_data] }).to include("dashboard:staff:#{staff_id}:2")
    end
  end

  # Ревью #280 (раунд 2): редактирование лида через wizard не теряет контекст
  # «Назад» — ни страницу списка (сохранение сдвигает лид в начало
  # сортировки), ни карточку сотрудника. Тапы идут через боевые
  # DashboardDrillCallback → WizardCallback → Engine.
  describe 'редактирование лида через wizard: возврат после сохранения' do
    let(:dms) { [] }
    let!(:agent) do
      TelegramUser.create!(tg_user_id: 172_001, tg_username: 'agent277w', first_name: 'Агент',
                           role: 'agent', status: 'active', assignable: true)
    end

    before do
      allow(tg_client).to receive(:send_message) do |text, **opts|
        dms << { text: text, keyboard: opts.dig(:reply_markup, :inline_keyboard) || [] }
        { 'message_id' => 2000 + dms.size }
      end
      allow(tg_client).to receive(:edit_message_reply_markup).and_return(true)
      allow(DispatcherDigestRefreshJob).to receive(:perform_async)
      allow(Telegram::WorkBot::LeadAnnouncer).to receive(:refresh!)
    end

    def tap_wizard(data)
      cb = { 'id' => 'cb_wiz', 'data' => data, 'from' => { 'id' => director.tg_user_id },
             'message' => { 'message_id' => 1, 'chat' => { 'id' => director.tg_user_id, 'type' => 'private' } } }
      Telegram::WorkBot::Callbacks::WizardCallback.new(callback_query: cb, tg_user: director,
                                                       args: data.split(':').drop(1), client: tg_client).call
    end

    def wizard_press(label)
      btn = dms.last[:keyboard].flatten.find { |b| b[:text].include?(label) }
      tap_wizard(btn[:callback_data])
    end

    def wizard_final_callbacks
      dms.last[:keyboard].flatten.map { |b| b[:callback_data] }
    end

    it 'список стр. 2 → лид → редактирование → «Назад» на страницу 2, не на пересчитанную 1' do
      lead = LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'new',
                               anchor_topic_key: 'dispatcher', tg_chat_id: -1_002_000_000_000,
                               assigned_to: agent, metadata: { 'name' => 'Старое Имя' })
      Array.new(12) do |i|
        LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'new',
                          anchor_topic_key: 'dispatcher', tg_chat_id: -1_002_000_000_000,
                          metadata: { 'name' => "Клиент #{i}" }).tap do |le|
          le.update_column(:updated_at, (i + 1).minutes.ago) # rubocop:disable Rails/SkipsModelValidations
        end
      end
      lead.update_column(:updated_at, 30.minutes.ago) # rubocop:disable Rails/SkipsModelValidations

      tap('dashboard:drill:leads', viewer: director)
      tap(button('▶️'), viewer: director)
      tap("dashboard:lead:#{lead.id}", viewer: director)
      edit_cb = button('✏️ Редактировать')
      expect(edit_cb).to eq("wiz:s:lead_edit:#{lead.id}:p2")

      tap_wizard(edit_cb)
      wizard_press('👤 Имя')
      Telegram::WorkBot::Wizard::Engine.new(tg_user: director, client: tg_client).text('Новое Имя')

      expect(lead.reload.metadata['name']).to eq('Новое Имя')
      expect(wizard_final_callbacks).to include('dashboard:leads:p:2')
      expect(wizard_final_callbacks).not_to include('dashboard:leads:p:1')
    end

    it 'карточка сотрудника → лид → редактирование → «Назад» в карточку сотрудника' do
      lead = LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'new',
                               anchor_topic_key: 'dispatcher', tg_chat_id: -1_002_000_000_000,
                               assigned_to: agent, metadata: { 'name' => 'Старое Имя' })

      tap("dashboard:staff:#{agent.id}:1", viewer: director)
      lead_cb = row_callback(/\Adashboard:lead:\d+:s\d+:1\z/)
      tap(lead_cb, viewer: director)
      edit_cb = button('✏️ Редактировать')
      expect(edit_cb).to eq("wiz:s:lead_edit:#{lead.id}:s#{agent.id}:1")

      tap_wizard(edit_cb)
      wizard_press('👤 Имя')
      Telegram::WorkBot::Wizard::Engine.new(tg_user: director, client: tg_client).text('Новое Имя')

      expect(lead.reload.metadata['name']).to eq('Новое Имя')
      expect(wizard_final_callbacks).to include("dashboard:staff:#{agent.id}:1")
      expect(wizard_final_callbacks).to include("dashboard:lead:#{lead.id}:s#{agent.id}:1:del")
    end
  end
end
