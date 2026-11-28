# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::DashboardStaffCard do
  let!(:staff) do
    TelegramUser.create!(tg_user_id: 150_001, tg_username: 'agent277', first_name: 'Агент',
                         role: 'agent', status: 'active', assignable: true)
  end
  let!(:other) do
    TelegramUser.create!(tg_user_id: 150_002, tg_username: 'other277', first_name: 'Другой',
                         role: 'agent', status: 'active', assignable: true)
  end

  def create_lead(assigned_to: staff, stage: 'new', name: nil, staff_test: false,
                  assigned_at: nil, first_contact_at: nil)
    LeadEvent.create!(
      lead_ref: create(:inquiry),
      source: 'site_form',
      current_stage: stage,
      anchor_topic_key: 'dispatcher',
      tg_chat_id: -1_002_000_000_000,
      staff_test: staff_test,
      assigned_to: assigned_to,
      assigned_at: assigned_at,
      first_contact_at: first_contact_at,
      metadata: name ? { 'name' => name } : {}
    )
  end

  def render(mode: :view, admin: false, page: 1)
    described_class.new(staff: staff, admin_viewer: admin, from_page: page, mode: mode).call
  end

  def callbacks(result)
    result.keyboard[:inline_keyboard].flatten.map { |b| b[:callback_data] }
  end

  describe ':view — метрики и под-списки' do
    before do
      @awaiting_overdue = create_lead(name: 'Ждёт контакта', assigned_at: 2.hours.ago)
      @awaiting_fresh = create_lead(name: 'Свежий', assigned_at: 10.minutes.ago)
      @in_sla = create_lead(name: 'В SLA', assigned_at: 1.day.ago, first_contact_at: 1.day.ago + 10.minutes)
      @out_sla = create_lead(name: 'Мимо SLA', assigned_at: 2.days.ago, first_contact_at: 2.days.ago + 2.hours)
      create_lead(name: 'Закрытый', stage: 'closed_won', assigned_at: 3.days.ago, first_contact_at: 3.days.ago + 5.minutes)
      create_lead(name: 'Чужой', assigned_to: other, assigned_at: 1.hour.ago)
      create_lead(name: 'probe', staff_test: true, assigned_at: 1.hour.ago)

      @open_task = ::Task.create!(assignee: staff, title: 'Показ квартиры', status: 'open', due_at: 1.day.from_now)
      @overdue_task = ::Task.create!(assignee: staff, title: 'Просроченная', status: 'open', due_at: 2.days.ago)
      @done_task = ::Task.create!(assignee: staff, title: 'Закрытая сегодня', status: 'done', due_at: 1.day.ago)
    end

    it 'рендерит метрики задач/лидов и SLA первого контакта' do
      text = render.text

      expect(text).to include("#{staff.display_name} (#{staff.mention})")
      expect(text).to include('Роль: <b>агент</b>')
      expect(text).to include('2 в работе')
      expect(text).to include('1 ⚠️ просрочено')
      expect(text).to include('1 закрыто сегодня')
      expect(text).to include('4 открытых')
      expect(text).to include('ждут 1-го контакта: 2')
      expect(text).to include('>30мин: 1 ⚠️')
      expect(text).to include('SLA 1-го контакта (7д):</b> 2/5 ≤30мин (40%)')
    end

    it 'открытые лиды — кнопки dashboard:lead:<id> с origin карточки; чужие/закрытые/probe исключены' do
      ids = callbacks(render(page: 2)).grep(/\Adashboard:lead:\d+:s\d+:\d+\z/)
                                     .map { |cb| cb.split(':')[2].to_i }

      expect(ids).to contain_exactly(@awaiting_overdue.id, @awaiting_fresh.id, @in_sla.id, @out_sla.id)
    end

    # Ревью #280: origin (s<staff_id>:<page>) — «Назад» из карточки лида
    # вернёт в карточку сотрудника на ту же страницу, а не в список лидов.
    it 'кнопка лида несёт origin — id сотрудника и страницу списка' do
      button = render(page: 3).keyboard[:inline_keyboard].flatten
                            .find { |b| b[:callback_data].start_with?("dashboard:lead:#{@in_sla.id}:") }

      expect(button[:callback_data]).to eq("dashboard:lead:#{@in_sla.id}:s#{staff.id}:3")
    end

    it 'лид с просроченным первым контактом помечен ⚠️ в кнопке' do
      button = render.keyboard[:inline_keyboard].flatten
                   .find { |b| b[:callback_data] == "dashboard:lead:#{@awaiting_overdue.id}:s#{staff.id}:1" }

      expect(button[:text]).to include('⚠️')
    end

    it 'задачи — читаемый список текстом, без drill-down колбэков' do
      result = render

      expect(result.text).to include("##{@open_task.id} Показ квартиры — срок")
      expect(result.text).to include("##{@overdue_task.id} Просроченная — ⚠️ просрочена")
      expect(result.text).not_to include("##{@done_task.id}")
      expect(callbacks(result).grep(/\Atask:/)).to be_empty
    end

    it 'admin видит edit-кнопку с текущей страницей, не-admin — нет' do
      expect(callbacks(render(admin: true, page: 2))).to include("dashboard:staff:#{staff.id}:2:edit")
      expect(callbacks(render(admin: false, page: 2))).not_to include("dashboard:staff:#{staff.id}:2:edit")
    end

    it '«Назад» ведёт на страницу списка, с которой пришли, «Обновить» — перерендер карточки' do
      result = render(page: 3)

      expect(callbacks(result)).to include('dashboard:staff:p:3')
      expect(callbacks(result)).to include("dashboard:staff:#{staff.id}:3")
    end

    it 'без назначений за 7 дней — честная строка SLA' do
      LeadEvent.delete_all

      expect(render.text).to include('SLA 1-го контакта (7д):</b> назначений не было')
    end
  end

  describe ':edit — admin-меню' do
    it 'кнопки роли/assignable/status + возврат к карточке' do
      result = render(mode: :edit, admin: true, page: 2)
      cbs = callbacks(result)

      expect(result.text).to include('✏️ <b>Редактирование:')
      expect(cbs).to include("dashboard:staff:#{staff.id}:2:role")
      expect(cbs).to include("dashboard:staff:#{staff.id}:2:assignable")
      expect(cbs).to include("dashboard:staff:#{staff.id}:2:status")
      expect(cbs).to include("dashboard:staff:#{staff.id}:2")
    end
  end

  describe ':role — выбор роли' do
    it 'кнопки всех ролей с setrole callback, текущая отмечена' do
      result = render(mode: :role, admin: true)
      cbs = callbacks(result)

      TelegramUser.roles.keys.each do |role|
        expect(cbs).to include("dashboard:staff:#{staff.id}:1:setrole:#{role}")
      end
      current = result.keyboard[:inline_keyboard].flatten
                     .find { |b| b[:callback_data] == "dashboard:staff:#{staff.id}:1:setrole:agent" }
      expect(current[:text]).to start_with('• ')
    end
  end

  describe ':status_confirm — подтверждение смены статуса' do
    it 'для active — деактивация с confirm/cancel, целевой статус в callback' do
      result = render(mode: :status_confirm, admin: true)

      expect(result.text).to include('Деактивировать')
      expect(callbacks(result)).to include("dashboard:staff:#{staff.id}:1:status_confirm:inactive")
      expect(callbacks(result)).to include("dashboard:staff:#{staff.id}:1:edit")
    end

    it 'для inactive — активация с целевым статусом active' do
      staff.update!(status: 'inactive')
      result = render(mode: :status_confirm, admin: true)

      expect(result.text).to include('Активировать')
      expect(callbacks(result)).to include("dashboard:staff:#{staff.id}:1:status_confirm:active")
    end
  end

  # Ревью #280: карточка рендерится с parse_mode HTML — пользовательские
  # строки (имя, email, заголовки задач) обязаны экранироваться.
  describe 'экранирование HTML' do
    # Без tg_username mention падает обратно на display_name — так HTML-опасная
    # строка проходит через все режимы карточки (view/edit/role/status_confirm).
    let!(:html_staff) do
      TelegramUser.create!(tg_user_id: 150_009, first_name: 'Агент <b>&Co</b>',
                           role: 'agent', status: 'active', assignable: true)
    end

    def render_html_staff(mode: :view)
      described_class.new(staff: html_staff, admin_viewer: false, from_page: 1, mode: mode).call
    end

    it 'имя/mention экранируются во всех режимах карточки' do
      %i[view edit role status_confirm].each do |mode|
        text = render_html_staff(mode: mode).text

        expect(text).to include('Агент &lt;b&gt;&amp;Co&lt;/b&gt;'), "режим #{mode} без экранирования"
        expect(text).not_to include('<b>&Co')
      end
    end

    it 'заголовки задач экранируются в списке' do
      ::Task.create!(assignee: html_staff, title: 'Показ <script> & "кавычки"', status: 'open', due_at: 1.day.from_now)

      text = render_html_staff.text
      expect(text).to include('Показ &lt;script&gt; &amp; "кавычки"')
      expect(text).not_to include('<script>')
    end

    # Ревью #280 (раунд 2): email не валидируется моделью — без escape
    # символ '<' ломал рендер карточки с Telegram Bad Request.
    it 'email экранируется в :view' do
      html_staff.update!(email: 'agent<b>@victory62.org')

      text = render_html_staff.text
      expect(text).to include('agent&lt;b&gt;@victory62.org')
      expect(text).not_to include('agent<b>@')
    end
  end
end
