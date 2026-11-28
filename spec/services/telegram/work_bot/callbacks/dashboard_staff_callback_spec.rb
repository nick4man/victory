# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Callbacks::DashboardStaffCallback do
  let!(:admin) do
    TelegramUser.create!(tg_user_id: 160_001, tg_username: 'root277', first_name: 'Рут',
                         role: 'admin', is_manager: true, status: 'active')
  end
  let!(:director) do
    TelegramUser.create!(tg_user_id: 160_002, tg_username: 'dir277', first_name: 'Дира',
                         role: 'director', is_manager: true, status: 'active')
  end
  let!(:staff) do
    TelegramUser.create!(tg_user_id: 160_003, tg_username: 'agent277', first_name: 'Агент',
                         role: 'agent', status: 'active', assignable: true)
  end

  let(:tg_client) do
    instance_double(
      Telegram::Client,
      edit_message_text: { 'message_id' => 100 },
      answer_callback_query: { 'ok' => true }
    )
  end

  def build_cb(viewer, data)
    {
      'id' => 'cb_staff_1',
      'from' => { 'id' => viewer.tg_user_id },
      'data' => data,
      'message' => {
        'message_id' => 555,
        'chat' => { 'id' => viewer.tg_user_id, 'type' => 'private' }
      }
    }
  end

  def invoke(viewer, *args)
    args = args.map(&:to_s)
    described_class.new(callback_query: build_cb(viewer, "dashboard:staff:#{args.join(':')}"),
                        tg_user: viewer, args: args, client: tg_client).call
  end

  def captured_edits
    edits = []
    allow(tg_client).to receive(:edit_message_text) do |text, opts|
      edits << [text, opts[:reply_markup]]
    end
    edits
  end

  describe 'просмотр карточки' do
    it 'manager+ (director) видит карточку без edit-кнопок' do
      invoke(director, staff.id)

      expect(tg_client).to have_received(:edit_message_text).with(
        a_string_matching(/👤.*Агент/m),
        hash_including(reply_markup: a_hash_including(:inline_keyboard))
      )
      expect(tg_client).to have_received(:answer_callback_query).with('cb_staff_1', text: nil, show_alert: false)
    end

    it 'admin видит edit-кнопку' do
      edits = captured_edits
      invoke(admin, staff.id)

      keyboard = edits.last[1][:inline_keyboard].flatten
      expect(keyboard.map { |b| b[:callback_data] }).to include("dashboard:staff:#{staff.id}:1:edit")
    end

    it '«Назад» возвращает на страницу списка, с которой пришли (не в начало)' do
      edits = captured_edits
      invoke(director, staff.id, 3)

      keyboard = edits.last[1][:inline_keyboard].flatten
      expect(keyboard.map { |b| b[:callback_data] }).to include('dashboard:staff:p:3')
    end

    it 'несуществующий id — вежливый отказ без изменений' do
      invoke(admin, 999_999)

      expect(tg_client).not_to have_received(:edit_message_text)
      expect(tg_client).to have_received(:answer_callback_query).with(
        'cb_staff_1', text: a_string_matching(/не найден/), show_alert: true
      )
    end

    it 'неизвестное действие — alert без изменений' do
      invoke(director, staff.id, 1, 'hack')

      expect(tg_client).not_to have_received(:edit_message_text)
      expect(tg_client).to have_received(:answer_callback_query).with(
        'cb_staff_1', text: a_string_matching(/Неизвестное действие/), show_alert: true
      )
    end

    it 'agent (не manager) отсекается manager_only-гейтом' do
      invoke(staff, staff.id)

      expect(tg_client).not_to have_received(:edit_message_text)
      expect(tg_client).to have_received(:answer_callback_query).with(
        'cb_staff_1', text: a_string_matching(/Только для руководителей/), show_alert: true
      )
    end
  end

  describe 'admin-only редактирование' do
    it 'admin открывает меню редактирования' do
      invoke(admin, staff.id, 2, 'edit')

      expect(tg_client).to have_received(:edit_message_text).with(
        a_string_matching(/✏️ <b>Редактирование:/),
        hash_including(:reply_markup)
      )
    end

    it 'legacy-формат без страницы (dashboard:staff:<id>:edit) тоже работает' do
      invoke(admin, staff.id, 'edit')

      expect(tg_client).to have_received(:edit_message_text).with(
        a_string_matching(/✏️ <b>Редактирование:/),
        hash_including(:reply_markup)
      )
    end

    it 'admin меняет роль: role и is_manager синхронно, тост + перерендер меню' do
      invoke(admin, staff.id, 2, 'setrole', 'manager')

      expect(staff.reload.role).to eq('manager')
      expect(staff.is_manager).to be(true)
      expect(tg_client).to have_received(:answer_callback_query).with(
        'cb_staff_1', text: a_string_matching(/✅ Роль обновлена: manager/), show_alert: false
      )
      expect(tg_client).to have_received(:edit_message_text).with(
        a_string_matching(/✅ Роль обновлена.*✏️ <b>Редактирование:/m),
        hash_including(:reply_markup)
      )
    end

    it 'понижение до agent снимает is_manager' do
      staff.update!(role: 'manager', is_manager: true)

      invoke(admin, staff.id, 1, 'setrole', 'agent')

      expect(staff.reload.role).to eq('agent')
      expect(staff.is_manager).to be(false)
    end

    it 'невалидная роль — alert без изменений' do
      invoke(admin, staff.id, 1, 'setrole', 'superuser')

      expect(staff.reload.role).to eq('agent')
      expect(tg_client).to have_received(:answer_callback_query).with(
        'cb_staff_1', text: a_string_matching(/Неизвестная роль/), show_alert: true
      )
    end

    it 'admin переключает assignable' do
      invoke(admin, staff.id, 1, 'assignable')

      expect(staff.reload.assignable).to be(false)
      expect(tg_client).to have_received(:edit_message_text).with(
        a_string_matching(/убран из подбора/), hash_including(:reply_markup)
      )
    end

    # Ревью #280: notice с именем сотрудника экранируется в HTML-правке
    # сообщения, но уходит сырым текстом в answer_callback_query.
    it 'имя с HTML-символами: экранировано в тексте, сырое в ack' do
      staff.update!(first_name: 'Агент <b>&Co</b>', tg_username: nil)
      invoke(admin, staff.id, 1, 'assignable')

      expect(tg_client).to have_received(:edit_message_text).with(
        a_string_matching(/Агент &lt;b&gt;&amp;Co&lt;\/b&gt;.*убран из подбора/m), hash_including(:reply_markup)
      )
      expect(tg_client).to have_received(:answer_callback_query).with(
        'cb_staff_1', text: '🚫 Агент <b>&Co</b> убран из подбора', show_alert: false
      )
    end

    it 'деактивация в два шага: confirm-экран, затем status_confirm применяет' do
      invoke(admin, staff.id, 1, 'status')
      expect(tg_client).to have_received(:edit_message_text).with(
        a_string_matching(/Деактивировать/), hash_including(:reply_markup)
      )
      expect(staff.reload.status).to eq('active')

      invoke(admin, staff.id, 1, 'status_confirm', 'inactive')
      expect(staff.reload.status).to eq('inactive')
      expect(staff.assignable).to be(false)
    end

    # Ревью #280 (раунд 2): целевой статус зашит в callback — повторный тап
    # по тому же подтверждению не переключает состояние обратно.
    it 'повторный status_confirm:inactive — no-op, сотрудник не активируется обратно' do
      invoke(admin, staff.id, 1, 'status_confirm', 'inactive')
      expect(staff.reload.status).to eq('inactive')

      invoke(admin, staff.id, 1, 'status_confirm', 'inactive')
      expect(staff.reload.status).to eq('inactive')
      expect(tg_client).to have_received(:answer_callback_query).with(
        'cb_staff_1', text: a_string_matching(/уже деактивирован/), show_alert: false
      )
    end

    it 'status_confirm без целевого статуса — alert без изменений' do
      invoke(admin, staff.id, 1, 'status_confirm')

      expect(staff.reload.status).to eq('active')
      expect(tg_client).to have_received(:answer_callback_query).with(
        'cb_staff_1', text: a_string_matching(/Неизвестный статус/), show_alert: true
      )
    end

    it 'активация inactive сотрудника' do
      staff.update!(status: 'inactive', assignable: false)

      invoke(admin, staff.id, 1, 'status_confirm', 'active')

      expect(staff.reload.status).to eq('active')
    end

    it 'себе роль/статус не меняем' do
      invoke(admin, admin.id, 1, 'setrole', 'agent')
      expect(admin.reload.role).to eq('admin')

      invoke(admin, admin.id, 1, 'status_confirm', 'inactive')
      expect(admin.reload.status).to eq('active')

      expect(tg_client).to have_received(:answer_callback_query).with(
        'cb_staff_1', text: a_string_matching(/Себе роль\/статус не меняем/), show_alert: true
      ).twice
    end
  end

  describe 'не-admin: вежливый отказ без изменений' do
    it 'edit — отказ, карточка не перерендеривается' do
      invoke(director, staff.id, 1, 'edit')

      expect(tg_client).not_to have_received(:edit_message_text)
      expect(tg_client).to have_received(:answer_callback_query).with(
        'cb_staff_1', text: a_string_matching(/только для admin/), show_alert: true
      )
    end

    it 'setrole — отказ, роль не меняется' do
      invoke(director, staff.id, 1, 'setrole', 'manager')

      expect(staff.reload.role).to eq('agent')
      expect(tg_client).to have_received(:answer_callback_query).with(
        'cb_staff_1', text: a_string_matching(/только для admin/), show_alert: true
      )
    end

    it 'assignable — отказ, флаг не меняется' do
      invoke(director, staff.id, 1, 'assignable')

      expect(staff.reload.assignable).to be(true)
    end

    it 'status_confirm — отказ, статус не меняется' do
      invoke(director, staff.id, 1, 'status_confirm')

      expect(staff.reload.status).to eq('active')
    end
  end
end
