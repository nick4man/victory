# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Kpi::ShowFunnel do
  let(:agent)    { TelegramUser.create!(tg_user_id: 111, role: 'agent', first_name: 'Ирина', status: 'active') }
  let(:director) { TelegramUser.create!(tg_user_id: 333, role: 'director', first_name: 'Оксана', status: 'active') }
  let(:week)   { Time.zone.parse('2026-09-07 00:00')..Time.zone.parse('2026-09-13 23:59:59') }
  let(:cohort) { Time.zone.parse('2026-07-20 00:00')..week.end }

  # «30 дней», «24 часа» считаются от Time.current — замораживаем, иначе спека протухнет.
  around { |ex| travel_to(Time.zone.parse('2026-09-14 10:00')) { ex.run } }

  def lead!(segment:, first_show_at:, contract_at: nil, property: nil, staff_test: false)
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'tg_dm', current_stage: contract_at ? 'contract' : 'show',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1, assigned_to: agent, segment: segment,
                      first_show_at: first_show_at, contract_at: contract_at, property: property, staff_test: staff_test)
  end

  def show!(lead, by:, at: lead.first_show_at, status: 'confirmed', objections: [], price: nil)
    ShowReport.create!(lead_event: lead, property: lead.property, conducted_by: by, reported_by: agent,
                       conducted_at: at, source: 'voice', status: status, objections: objections, offered_price: price)
  end

  describe '#call' do
    it 'матрица сегмент × кто показывал: показы и договоры считаются внутри ячейки' do
      l1 = lead!(segment: 'cold', first_show_at: week.begin + 1.day)
      l2 = lead!(segment: 'cold', first_show_at: week.begin + 2.days, contract_at: week.begin + 4.days)
      l3 = lead!(segment: 'cash', first_show_at: week.begin + 2.days, contract_at: week.begin + 5.days)
      show!(l1, by: agent)
      show!(l2, by: agent)
      show!(l3, by: director)

      res = described_class.new(week: week, cohort: cohort).call
      expect(res.week_shows).to eq(3)
      expect(res.matrix['cold']['агент']).to eq(shows: 2, contracts: 1)
      expect(res.matrix['cash']['руководитель']).to eq(shows: 1, contracts: 1)
      expect(res.matrix['cold']['руководитель']).to eq(shows: 0, contracts: 0)
    end

    it 'nil-сегмент идёт отдельной строкой «не указан», staff_test не считается' do
      lead!(segment: nil, first_show_at: week.begin + 1.day).then { |l| show!(l, by: director) }
      lead!(segment: 'cash', first_show_at: week.begin + 1.day, staff_test: true).then { |l| show!(l, by: director) }
      res = described_class.new(week: week, cohort: cohort).call
      expect(res.matrix['не указан']['руководитель'][:shows]).to eq(1)
      expect(res.matrix.dig('cash', 'руководитель', :shows).to_i).to eq(0)
    end

    it 'pending отчёт — не показ; лид с first_show_at без подтверждённого отчёта — «без отчёта»' do
      l = lead!(segment: 'cold', first_show_at: week.begin + 1.day)
      show!(l, by: agent, status: 'pending_confirm')
      res = described_class.new(week: week, cohort: cohort).call
      expect(res.week_shows).to eq(0)
      expect(res.unreported).to eq(1)
    end

    it 'объекты: без показов 30 дней, медиана дней до первого показа, ≥3 показов без договора' do
      idle  = create(:property, :on_site, in_ad: true, deal_state: 'ad', published_at: 40.days.ago)
      quick = create(:property, :on_site, in_ad: true, deal_state: 'ad', published_at: week.begin - 10.days)
      stuck = create(:property, :on_site, in_ad: true, deal_state: 'ad', published_at: week.begin - 20.days)

      lq = lead!(segment: 'cash', first_show_at: week.begin, property: quick)
      show!(lq, by: director)
      # stuck: три показа по 10 дней после публикации → медиана по объектам [10, 10] = 10;
      # последний показ 17 дней назад → объект не «без показов 30 дней».
      3.times do |i|
        l = lead!(segment: 'cold', first_show_at: week.begin - 10.days + i.hours, property: stuck)
        show!(l, by: agent)
      end

      res = described_class.new(week: week, cohort: cohort).call
      expect(res.objects[:no_shows_30d]).to include(idle.id)
      expect(res.objects[:no_shows_30d]).not_to include(quick.id, stuck.id)
      expect(res.objects[:median_days_to_first_show]).to eq(10)
      expect(res.objects[:stuck]).to eq([stuck.id])
    end
  end

  describe '#render_html' do
    it 'содержит матрицу, объекты и предупреждение про сравнение внутри сегмента' do
      l = lead!(segment: 'cold', first_show_at: week.begin + 1.day)
      show!(l, by: agent)
      html = described_class.new(week: week, cohort: cohort).render_html
      expect(html).to include('Показы', 'Холодный', 'агент', 'внутри сегмента')
    end
  end

  describe '.objections_summary' do
    it 'агрегирует теги и исходы по объекту' do
      property = create(:property)
      l1 = lead!(segment: 'cold', first_show_at: 3.days.ago, property: property)
      l2 = lead!(segment: 'cash', first_show_at: 2.days.ago, property: property)
      show!(l1, by: agent, objections: ['маленькая кухня', 'первый этаж'])
      show!(l2, by: director, objections: ['Маленькая кухня'], price: 5_200_000)
      s = described_class.objections_summary(property: property)
      expect(s[:shows]).to eq(2)
      expect(s[:objections].first).to eq(['маленькая кухня', 2])
      expect(s[:offered_prices]).to eq([5_200_000])
    end
  end
end
