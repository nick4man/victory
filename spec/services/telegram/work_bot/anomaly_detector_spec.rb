# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::AnomalyDetector do
  let(:today) { Date.parse('2026-05-29') }
  before { travel_to today.to_time + 12.hours }

  # 5 staff. По-умолчанию все «healthy». Каждый тест портит одного.
  let!(:alice) { create_staff(11_001, 'Алиса',  'alice') }
  let!(:bob)   { create_staff(11_002, 'Боб',    'bob') }
  let!(:carol) { create_staff(11_003, 'Кэрол',  'carol') }
  let!(:dave)  { create_staff(11_004, 'Дэйв',   'dave') }
  let!(:eve)   { create_staff(11_005, 'Ева',    'eve') }

  def create_staff(id, first_name, username)
    TelegramUser.create!(
      tg_user_id: id, status: 'active', role: 'agent',
      first_name: first_name, tg_username: username
    )
  end

  def create_task(staff:, status: 'open', due_at: 2.days.from_now, **attrs)
    Task.create!(
      { assignee_id: staff.id, title: 'T', status: status, due_at: due_at,
        kind: 'call', priority: 'normal' }.merge(attrs)
    )
  end

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

  describe '.run' do
    context 'overdue_rate (cross-staff, live)' do
      it 'возвращает Anomaly когда один staff существенно выше остальных' do
        # 4 staff — healthy: 5 open, 0 overdue
        [alice, bob, carol, dave].each do |s|
          5.times { create_task(staff: s, due_at: 2.days.from_now) }
        end
        # Eve — outlier: 10 open, 6 overdue (60%)
        4.times { create_task(staff: eve, due_at: 2.days.from_now) }
        6.times { create_task(staff: eve, due_at: 1.day.ago) }

        anomalies = described_class.run.select { |a| a.metric == :overdue_rate }
        expect(anomalies.size).to eq(1)
        a = anomalies.first
        expect(a.staff).to eq(eve)
        expect(a.value).to be_within(0.01).of(0.6)
        expect(a.baseline).to eq(0.0) # median across healthy staff
        expect(a.deviation_label).to be_in(%w[существенное значительное])
        expect(a.context[:open_tasks]).to eq(10)
      end

      it 'не триггерит при равных rate (всем плохо одинаково)' do
        [alice, bob, carol, dave, eve].each do |s|
          3.times { create_task(staff: s, due_at: 1.day.ago) }
        end
        anomalies = described_class.run.select { |a| a.metric == :overdue_rate }
        expect(anomalies).to be_empty
      end

      it 'пропускает staff с < 3 open tasks (нет baseline)' do
        [alice, bob, carol, dave].each do |s|
          5.times { create_task(staff: s, due_at: 2.days.from_now) }
        end
        # Eve — только 2 task (ниже MIN_OPEN_TASKS_FOR_OVERDUE)
        2.times { create_task(staff: eve, due_at: 1.day.ago) }

        anomalies = described_class.run.select { |a| a.metric == :overdue_rate }
        expect(anomalies).to be_empty
      end

      it 'пропускает alert когда rate < MIN_OVERDUE_RATE_ABSOLUTE (шум)' do
        # 4 healthy + 1 «outlier» с 15% rate — z может быть высокий но
        # absolute ниже порога
        [alice, bob, carol, dave].each do |s|
          10.times { create_task(staff: s, due_at: 2.days.from_now) }
        end
        17.times { create_task(staff: eve, due_at: 2.days.from_now) }
        3.times  { create_task(staff: eve, due_at: 1.day.ago) } # 15%

        anomalies = described_class.run.select { |a| a.metric == :overdue_rate }
        expect(anomalies).to be_empty
      end

      it 'не считает inactive staff' do
        [alice, bob, carol, dave].each do |s|
          5.times { create_task(staff: s, due_at: 2.days.from_now) }
        end
        eve.update!(status: 'inactive')
        10.times { create_task(staff: eve, due_at: 1.day.ago) }

        anomalies = described_class.run.select { |a| a.metric == :overdue_rate }
        expect(anomalies).to be_empty
      end

      it 'пропускает если выборка < MIN_STAFF_SAMPLE (4 staff с baseline)' do
        # Только 3 staff имеют >= 3 open tasks (baselineable).
        # Dave с 1 task < MIN_OPEN_TASKS_FOR_OVERDUE → не попадёт в map.
        # Eve без tasks. Итого 3 staff в выборке → меньше MIN_STAFF_SAMPLE.
        [alice, bob, carol].each do |s|
          5.times { create_task(staff: s, due_at: 2.days.from_now) }
        end
        create_task(staff: dave, due_at: 1.day.ago)

        anomalies = described_class.run.select { |a| a.metric == :overdue_rate }
        expect(anomalies).to be_empty
      end
    end

    context 'first_contact_delay_30m_miss (cross-staff rolling)' do
      it 'триггерит когда у одного miss-rate существенно выше' do
        # 4 healthy: 10 leads, 9 in 30m → 10% miss
        [alice, bob, carol, dave].each do |s|
          create_metric(staff: s, date: today - 5.days, leads_assigned: 10, leads_first_contact_in_30m: 9)
        end
        # Eve — outlier: 10 leads, 3 in 30m → 70% miss
        create_metric(staff: eve, date: today - 5.days, leads_assigned: 10, leads_first_contact_in_30m: 3)

        anomalies = described_class.run.select { |a| a.metric == :first_contact_delay_30m_miss }
        expect(anomalies.size).to eq(1)
        expect(anomalies.first.staff).to eq(eve)
        expect(anomalies.first.value).to be_within(0.01).of(0.7)
      end

      it 'пропускает staff с < 5 leads_assigned суммарно' do
        [alice, bob, carol, dave].each do |s|
          create_metric(staff: s, date: today - 5.days, leads_assigned: 10, leads_first_contact_in_30m: 9)
        end
        # Eve — только 3 leads (ниже порога)
        create_metric(staff: eve, date: today - 5.days, leads_assigned: 3, leads_first_contact_in_30m: 0)

        anomalies = described_class.run.select { |a| a.metric == :first_contact_delay_30m_miss }
        expect(anomalies).to be_empty
      end

      it 'не триггерит при miss-rate < MIN_MISS_RATE_ABSOLUTE' do
        [alice, bob, carol, dave].each do |s|
          create_metric(staff: s, date: today - 5.days, leads_assigned: 10, leads_first_contact_in_30m: 10)
        end
        # Eve — 25% miss (выше всех, но ниже abs threshold 30%)
        create_metric(staff: eve, date: today - 5.days, leads_assigned: 20, leads_first_contact_in_30m: 15)

        anomalies = described_class.run.select { |a| a.metric == :first_contact_delay_30m_miss }
        expect(anomalies).to be_empty
      end
    end

    context 'completion_rate_drop (per-staff longitudinal)' do
      it 'триггерит когда у staff падение completion rate >= 20pp' do
        # Eve — prior 14d (8-21 дней назад): assigned 20, completed 18 = 90%
        10.times do |i|
          create_metric(staff: eve, date: today - (8 + i).days,
                        tasks_assigned: 2, tasks_completed: rand >= 0.1 ? 2 : 1)
        end
        # Override: ensure 90% baseline
        StaffMetric.where(staff: eve).where(date: ((today - 21.days)..(today - 8.days))).destroy_all
        10.times do |i|
          create_metric(staff: eve, date: today - (8 + i).days,
                        tasks_assigned: 2, tasks_completed: 2)
        end
        # Current 7d: assigned 10, completed 5 = 50%
        5.times do |i|
          create_metric(staff: eve, date: today - i.days,
                        tasks_assigned: 2, tasks_completed: 1)
        end

        anomalies = described_class.run.select { |a| a.metric == :completion_rate_drop }
        eve_anomaly = anomalies.find { |a| a.staff == eve }
        expect(eve_anomaly).not_to be_nil
        expect(eve_anomaly.baseline).to be_within(0.01).of(1.0)
        expect(eve_anomaly.value).to be_within(0.01).of(0.5)
        expect(eve_anomaly.context[:drop_pp]).to eq(50)
      end

      it 'не триггерит без достаточного prior history (< 10 samples)' do
        # Только 5 prior samples
        5.times do |i|
          create_metric(staff: eve, date: today - (8 + i).days,
                        tasks_assigned: 2, tasks_completed: 2)
        end
        # Current 5 samples: drop
        5.times do |i|
          create_metric(staff: eve, date: today - i.days,
                        tasks_assigned: 2, tasks_completed: 0)
        end

        anomalies = described_class.run.select { |a| a.metric == :completion_rate_drop }
        expect(anomalies.find { |a| a.staff == eve }).to be_nil
      end

      it 'не триггерит при drop < 20pp' do
        # Prior 14d: 100% → Current 7d: 85% (drop 15pp)
        10.times do |i|
          create_metric(staff: eve, date: today - (8 + i).days,
                        tasks_assigned: 2, tasks_completed: 2)
        end
        5.times do |i|
          create_metric(staff: eve, date: today - i.days,
                        tasks_assigned: 20, tasks_completed: 17)
        end

        anomalies = described_class.run.select { |a| a.metric == :completion_rate_drop }
        expect(anomalies.find { |a| a.staff == eve }).to be_nil
      end

      it 'не считает staff с tasks_assigned=0 в prior (no baseline)' do
        # 10 prior samples но все assigned=0
        10.times do |i|
          create_metric(staff: eve, date: today - (8 + i).days,
                        tasks_assigned: 0, tasks_completed: 0)
        end
        5.times do |i|
          create_metric(staff: eve, date: today - i.days,
                        tasks_assigned: 5, tasks_completed: 0)
        end

        anomalies = described_class.run.select { |a| a.metric == :completion_rate_drop }
        expect(anomalies.find { |a| a.staff == eve }).to be_nil
      end
    end

    context 'integration — empty / no signal' do
      it 'возвращает empty array на чистой БД' do
        expect(described_class.run).to eq([])
      end

      it 'возвращает empty когда все метрики в норме' do
        [alice, bob, carol, dave, eve].each do |s|
          5.times { create_task(staff: s, due_at: 2.days.from_now) }
          create_metric(staff: s, date: today - 1.day, leads_assigned: 10, leads_first_contact_in_30m: 10)
        end

        expect(described_class.run).to eq([])
      end
    end
  end

  # === Чистая математика ===
  describe 'math helpers' do
    let(:detector) { described_class.new }

    it 'median_of для odd-length' do
      expect(detector.send(:median_of, [1, 2, 3, 4, 5])).to eq(3)
    end

    it 'median_of для even-length' do
      expect(detector.send(:median_of, [1, 2, 3, 4])).to eq(2.5)
    end

    it 'median_of empty → 0.0' do
      expect(detector.send(:median_of, [])).to eq(0.0)
    end

    it 'mad_of robust к outliers' do
      # 4 точки одинаковые + 1 outlier — MAD маленький (median deviations близок к 0)
      values = [0.1, 0.1, 0.1, 0.1, 0.9]
      median = detector.send(:median_of, values) # 0.1
      mad = detector.send(:mad_of, values, median)
      expect(mad).to eq(0.0) # median deviations: [0,0,0,0,0.8] → median=0
    end

    it 'modified_z_score возвращает 0 при mad=0' do
      expect(detector.send(:modified_z_score, 5.0, 1.0, 0.0)).to eq(0.0)
    end

    it 'modified_z_score = 3.5 threshold при z exactly 3.5' do
      # z = (value-median) * 0.6745 / mad. Подбираем чтобы z = 3.5.
      # value=0.6, median=0.1, mad=0.0964 → z ≈ 3.5
      expect(detector.send(:modified_z_score, 0.6, 0.1, 0.0964)).to be_within(0.01).of(3.5)
    end
  end
end
