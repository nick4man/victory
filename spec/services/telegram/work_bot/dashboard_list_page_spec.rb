# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::DashboardListPage do
  let!(:director) do
    TelegramUser.create!(tg_user_id: 130_001, tg_username: 'dir277', first_name: 'Дира',
                         role: 'director', is_manager: true, status: 'active', assignable: false)
  end

  def create_lead(stage: 'new', staff_test: false, assigned_to: nil, assigned_at: nil, name: nil)
    LeadEvent.create!(
      lead_ref: create(:inquiry),
      source: 'site_form',
      current_stage: stage,
      anchor_topic_key: 'dispatcher',
      tg_chat_id: -1_002_000_000_000,
      staff_test: staff_test,
      assigned_to: assigned_to,
      assigned_at: assigned_at,
      metadata: name ? { 'name' => name } : {}
    )
  end

  def create_agent(idx)
    TelegramUser.create!(tg_user_id: 140_000 + idx, tg_username: "agent#{idx}", first_name: "Агент#{idx}",
                         role: 'agent', status: 'active', assignable: true)
  end

  def render(section, page)
    described_class.new(section: section, page: page).call
  end

  def row_callbacks(result)
    result.keyboard[:inline_keyboard].map { |row| row.map { |b| b[:callback_data] } }
  end

  def lead_ids_on_page(result)
    row_callbacks(result).flatten.grep(/\Adashboard:lead:\d+\z/).map { |cb| cb.split(':').last.to_i }
  end

  def staff_ids_on_page(result)
    row_callbacks(result).flatten.grep(/\Adashboard:staff:\d+:\d+\z/).map { |cb| cb.split(':')[2].to_i }
  end

  describe 'лиды — постраничный просмотр' do
    let!(:leads) { Array.new(31) { |i| create_lead(name: "Клиент #{i}") } }

    it '30+ лидов листаются до конца: страницы покрывают все записи без дублей' do
      pages = (1..4).map { |p| render(:leads, p) }
      seen = pages.flat_map { |r| lead_ids_on_page(r) }

      expect(seen.size).to eq(31)
      expect(seen.uniq.size).to eq(31)
      expect(seen.sort).to eq(leads.map(&:id).sort)
      expect(pages.map { |r| lead_ids_on_page(r).size }).to eq([8, 8, 8, 7])
    end

    it 'страницы стабильны при повторном рендере (детерминированная сортировка)' do
      first = render(:leads, 2)
      second = render(:leads, 2)

      expect(first.text).to eq(second.text)
      expect(first.keyboard).to eq(second.keyboard)
    end

    it 'первая страница — без ◀️, последняя — без ▶️' do
      first = row_callbacks(render(:leads, 1)).flatten
      last = row_callbacks(render(:leads, 4)).flatten

      expect(first).not_to include('dashboard:leads:p:0')
      expect(first).to include('dashboard:leads:p:2')
      expect(last).to include('dashboard:leads:p:3')
      expect(last).not_to include('dashboard:leads:p:5')
    end

    it 'номер страницы закодирован в callback_data навигации' do
      rows = row_callbacks(render(:leads, 3))

      expect(rows[-2]).to eq(%w[dashboard:leads:p:2 dashboard:leads:p:3 dashboard:leads:p:4])
      # «Обновить» в футере перерендеривает текущую страницу, а не сводку
      expect(rows[-1]).to include('dashboard:leads:p:3')
    end

    it 'строки списка — кнопки с callback_data dashboard:lead:<id>' do
      ids = lead_ids_on_page(render(:leads, 1))
      expect(ids.size).to eq(8)
      expect(ids).to all(be_a(Integer))
    end

    it 'page за пределами диапазона зажимается к последней странице' do
      expect(render(:leads, 99).keyboard).to eq(render(:leads, 4).keyboard)
      expect(render(:leads, 0).keyboard).to eq(render(:leads, 1).keyboard)
    end

    it 'staff_test и закрытые лиды не попадают в список' do
      create_lead(staff_test: true, name: 'probe')
      create_lead(stage: 'closed_won', name: 'закрытый')

      result = render(:leads, 1)
      expect(result.text).to include('Открытых лидов: <b>31</b>')
      expect(lead_ids_on_page(result).size).to eq(8)
    end

    it 'alert-блок «ждут первого контакта» остаётся ограничен 5 записями' do
      create_list = Array.new(6) { create_lead(assigned_to: director, assigned_at: 2.hours.ago) }

      result = render(:leads, 1)
      expect(result.text).to include('⚠️ Ждут первого контакта')
      listed = result.text.scan(/• Лид #\d+/).size
      expect(listed).to eq(5)
      expect(create_list.map(&:id)).to include(result.text[/• Лид #(\d+)/, 1].to_i)
    end
  end

  describe 'сотрудники — постраничный просмотр' do
    let!(:agents) { Array.new(18) { |i| create_agent(i) } }

    it '18 сотрудников листаются по 8 на странице, admin исключён' do
      TelegramUser.create!(tg_user_id: 149_999, tg_username: 'root277', first_name: 'Root',
                           role: 'admin', status: 'active', assignable: true)

      pages = (1..3).map { |p| render(:staff, p) }
      seen = pages.flat_map { |r| staff_ids_on_page(r) }

      expect(seen.size).to eq(18)
      expect(seen.uniq.size).to eq(18)
      expect(seen.sort).to eq(agents.map(&:id).sort)
      expect(pages.map { |r| staff_ids_on_page(r).size }).to eq([8, 8, 2])
    end

    it 'страницы стабильны при повторном рендере' do
      first = render(:staff, 2)
      second = render(:staff, 2)

      expect(first.text).to eq(second.text)
      expect(first.keyboard).to eq(second.keyboard)
    end

    it 'строки списка — кнопки с callback_data dashboard:staff:<id>:<page>' do
      ids = staff_ids_on_page(render(:staff, 1))
      expect(ids.size).to eq(8)
    end

    it 'callback строки несёт номер страницы — «Назад» из карточки вернёт на неё же' do
      rows = row_callbacks(render(:staff, 2)).flatten

      expect(rows.grep(/\Adashboard:staff:\d+:2\z/).size).to eq(8)
    end

    it 'кнопка содержит метрики сотрудника' do
      agent = agents.first
      ::Task.create!(assignee: agent, title: 'Показ', status: 'open', due_at: 1.day.from_now)
      ::Task.create!(assignee: agent, title: 'Просроченная', status: 'open', due_at: 2.days.ago)
      create_lead(assigned_to: agent, assigned_at: 1.hour.ago)

      label = render(:staff, 1).keyboard[:inline_keyboard]
                              .flatten.find { |b| b[:callback_data] == "dashboard:staff:#{agent.id}:1" }[:text]

      expect(label).to include('2 в работе')
      expect(label).to include('1 ⚠️')
      expect(label).to include('лидов 1')
    end

    it 'первая страница — без ◀️, последняя — без ▶️' do
      first = row_callbacks(render(:staff, 1)).flatten
      last = row_callbacks(render(:staff, 3)).flatten

      expect(first).not_to include('dashboard:staff:p:0')
      expect(first).to include('dashboard:staff:p:2')
      expect(last).to include('dashboard:staff:p:2')
      expect(last).not_to include('dashboard:staff:p:4')
    end
  end
end
