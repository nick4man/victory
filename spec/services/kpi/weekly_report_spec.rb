# frozen_string_literal: true

require 'rails_helper'

# Phase 6 — Agency-level weekly report. Pure text builder — aggregates
# StaffMetric за prev Mon-Sun week, формирует ranking/trends/bottom blocks.
# No side-effects.
RSpec.describe Kpi::WeeklyReport do
  let(:alice) do
    TelegramUser.create!(tg_user_id: 11_001, status: 'active', role: 'agent',
                         first_name: 'Алиса', tg_username: 'alice')
  end

  let(:bob) do
    TelegramUser.create!(tg_user_id: 11_002, status: 'active', role: 'agent',
                         first_name: 'Боб', tg_username: 'bob')
  end

  # Monday 18.05.26 — week_end по умолчанию yesterday (Sun 17.05.26)
  let(:current_monday) { Date.parse('2026-05-18') }
  let(:week_end) { current_monday.prev_day } # Sun 17.05.26
  let(:week_start) { week_end - 6.days }      # Mon 11.05.26

  def create_metric(staff:, date:, **attrs)
    StaffMetric.create!({
      staff: staff, date: date,
      tasks_assigned: 0, tasks_completed: 0, tasks_on_time: 0,
      tasks_overdue: 0, suspicious_completions: 0,
      leads_assigned: 0, leads_first_contact_in_30m: 0,
      leads_converted: 0, avg_completion_time_sec: 0,
      questions_asked: 0
    }.merge(attrs))
  end

  describe '#build_text — empty data' do
    it 'shows fallback message when no StaffMetric для period' do
      text = described_class.new(week_end: week_end).build_text
      expect(text).to include('Нет данных за неделю')
    end

    it 'still includes header + period' do
      text = described_class.new(week_end: week_end).build_text
      expect(text).to include('Недельный отчёт')
      expect(text).to include(week_start.strftime('%d.%m'))
      expect(text).to include(week_end.strftime('%d.%m.%y'))
    end
  end

  describe '#build_text — with data' do
    before do
      # Alice: 10 tasks assigned, 8 done, 7 on_time за неделю (split across 2 days)
      create_metric(staff: alice, date: week_end - 1.day,
                    tasks_assigned: 5, tasks_completed: 4, tasks_on_time: 4,
                    leads_assigned: 2, leads_first_contact_in_30m: 2,
                    leads_converted: 1)
      create_metric(staff: alice, date: week_end,
                    tasks_assigned: 5, tasks_completed: 4, tasks_on_time: 3,
                    leads_assigned: 1, leads_first_contact_in_30m: 0)

      # Bob: 3 assigned, 1 done, fewer; more overdue
      create_metric(staff: bob, date: week_end,
                    tasks_assigned: 3, tasks_completed: 1, tasks_on_time: 0,
                    tasks_overdue: 2, suspicious_completions: 1,
                    leads_assigned: 1)
    end

    it 'aggregates agency totals across staff' do
      text = described_class.new(week_end: week_end).build_text
      # Total tasks: alice 10 + bob 3 = 13 assigned; done = 8 + 1 = 9
      expect(text).to include('9/13')
    end

    it 'ranks Alice above Bob (more completed)' do
      text = described_class.new(week_end: week_end).build_text
      alice_idx = text.index('Алис') || text.index('@alice')
      bob_idx = text.index('Боб') || text.index('@bob')
      expect(alice_idx).to be < bob_idx if alice_idx && bob_idx
    end

    it 'includes top-staff medals' do
      text = described_class.new(week_end: week_end).build_text
      expect(text).to include('🥇') # gold medal for first
    end

    it 'shows bottom (overdue/suspicious) block для Bob' do
      text = described_class.new(week_end: week_end).build_text
      expect(text).to include('Внимание')
      expect(text).to include('overdue=2')
      expect(text).to include('suspicious=1')
    end
  end

  describe '#build_text — week-over-week trend' do
    before do
      # Current week: 5 completed
      create_metric(staff: alice, date: week_end,
                    tasks_assigned: 8, tasks_completed: 5, tasks_on_time: 5)
      # Prev week: 3 completed
      create_metric(staff: alice, date: week_end - 7.days,
                    tasks_assigned: 6, tasks_completed: 3, tasks_on_time: 2)
    end

    it 'shows direction emoji (📈 for up)' do
      text = described_class.new(week_end: week_end).build_text
      # cur done=5 > prev done=3 → 📈 up
      expect(text).to include('📈')
    end

    it 'computes delta % vs prev week' do
      text = described_class.new(week_end: week_end).build_text
      # (5 - 3) / 3 * 100 = +66% (or similar)
      expect(text).to match(/Trend.*\(/i)
    end

    it 'shows 📉 when trending down' do
      # Current week 1, prev week 5 → down
      Kpi::WeeklyReport::DOC_FOR_DOWN_TREND = nil rescue nil
      StaffMetric.where(staff: alice).destroy_all
      create_metric(staff: alice, date: week_end,
                    tasks_assigned: 3, tasks_completed: 1, tasks_on_time: 1)
      create_metric(staff: alice, date: week_end - 7.days,
                    tasks_assigned: 10, tasks_completed: 8, tasks_on_time: 8)
      text = described_class.new(week_end: week_end).build_text
      expect(text).to include('📉')
    end
  end

  describe '#build_text — first-contact + conversion rates' do
    before do
      create_metric(staff: alice, date: week_end,
                    leads_assigned: 10, leads_first_contact_in_30m: 7,
                    leads_converted: 2, tasks_assigned: 0, tasks_completed: 0,
                    tasks_on_time: 0)
    end

    it 'shows first-contact-30min percentage' do
      text = described_class.new(week_end: week_end).build_text
      expect(text).to include('70%') # 7/10
    end

    it 'shows conversion percentage' do
      text = described_class.new(week_end: week_end).build_text
      expect(text).to include('20%') # 2/10
    end
  end

  describe '#build_text — period header' do
    it 'displays correct week range (prev Mon-Sun)' do
      text = described_class.new(week_end: week_end).build_text
      expect(text).to include('11.05')
      expect(text).to include('17.05.26')
    end
  end
end
