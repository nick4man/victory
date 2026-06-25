# frozen_string_literal: true

module Telegram
  module WorkBot
    # Phase 16.7 — Pro-active детектор отклонений у отдельных сотрудников.
    #
    # Идея: shipped Phase 15 digest + weekly summary — расписанные (08:30 / Пн 10:00).
    # Если у одного сотрудника overdue rate 42% когда у остальных 8% — director
    # узнаёт через 5 дней. Здесь — точечный alert в течение 24 часов.
    #
    # Стат. метод: Modified Z-Score (median + MAD), не классический 2σ.
    # Mean/stddev fragile при малой выборке (~7-12 staff): один outlier тянет
    # mean и завышает свой собственный threshold. MAD robust к этому.
    # Threshold > 3.5 (Iglewicz/Hoaglin, 1993) ≈ 2.7σ на нормальных данных.
    #
    # Метрики (3):
    #   • overdue_rate                   — cross-staff, live (Task)
    #   • first_contact_delay_30m_miss   — cross-staff rolling, StaffMetric 14d
    #   • completion_rate_drop           — per-staff longitudinal (7d vs prior 14d)
    #
    # Min-absolute guard защищает от noise («1 task overdue из 2» не = anomaly).
    # Min-sample guard защищает от false-positive на свежем staff (нет baseline).
    #
    # Контракт: stateless. `.run(window: 14.days)` → Array<Anomaly>.
    # Caller (AnomalyDetectorJob) сам решает что делать с результатом.
    class AnomalyDetector
      # Threshold для modified Z-Score. > 3.5 = существенное отклонение.
      MAD_THRESHOLD = 3.5

      # Минимальное число staff в выборке (cross-staff метрики). < 4 — выборка
      # слишком мала для MAD-расчёта (нужно хотя бы 4 точки чтобы median + MAD
      # имели смысл).
      MIN_STAFF_SAMPLE = 4

      Anomaly = Struct.new(
        :staff, :metric, :value, :baseline, :deviation_label, :context,
        keyword_init: true
      )

      def self.run(window: 14.days)
        new(window: window).run
      end

      def initialize(window: 14.days)
        @window = window
        @today  = Date.current
      end

      def run
        [
          detect_overdue_rate,
          detect_first_contact_miss,
          detect_completion_rate_drop
        ].flatten.compact
      end

      private

      # === Метрика 1: live overdue rate (cross-staff) ===

      MIN_OPEN_TASKS_FOR_OVERDUE = 3
      MIN_OVERDUE_RATE_ABSOLUTE  = 0.20 # 20% — ниже считаем шумом

      def detect_overdue_rate
        per_staff = staff_overdue_rate_map
        return [] if per_staff.size < MIN_STAFF_SAMPLE

        values = per_staff.values
        median = median_of(values)
        mad    = mad_of(values, median)

        per_staff.filter_map do |staff, rate|
          next if rate < MIN_OVERDUE_RATE_ABSOLUTE

          label = outlier_label(rate, median, mad, MIN_OVERDUE_RATE_ABSOLUTE)
          next if label.nil?

          Anomaly.new(
            staff: staff,
            metric: :overdue_rate,
            value: rate,
            baseline: median,
            deviation_label: label,
            context: { open_tasks: per_staff_open_tasks_count(staff) }
          )
        end
      end

      # Map TelegramUser → overdue_rate (Float 0..1) для каждого active staff
      # с >= MIN_OPEN_TASKS_FOR_OVERDUE open tasks. Не включаем staff без tasks —
      # они не имеют baseline.
      def staff_overdue_rate_map
        open_by_staff = ::Task.status_open.group(:assignee_id).count
        overdue_by_staff = ::Task.status_open.overdue.group(:assignee_id).count

        result = {}
        open_by_staff.each do |staff_id, open_count|
          next if open_count < MIN_OPEN_TASKS_FOR_OVERDUE

          staff = TelegramUser.find_by(id: staff_id, status: 'active')
          next if staff.nil?

          overdue = overdue_by_staff[staff_id].to_i
          result[staff] = overdue.to_f / open_count
        end
        result
      end

      def per_staff_open_tasks_count(staff)
        ::Task.status_open.where(assignee_id: staff.id).count
      end

      # === Метрика 2: first_contact_delay_30m_miss (cross-staff rolling) ===

      MIN_LEADS_FOR_FIRST_CONTACT = 5
      MIN_MISS_RATE_ABSOLUTE      = 0.30 # 30% — выше = реально проблемно

      def detect_first_contact_miss
        per_staff = staff_first_contact_miss_map
        return [] if per_staff.size < MIN_STAFF_SAMPLE

        values = per_staff.values
        median = median_of(values)
        mad    = mad_of(values, median)

        per_staff.filter_map do |staff, miss_rate|
          next if miss_rate < MIN_MISS_RATE_ABSOLUTE

          label = outlier_label(miss_rate, median, mad, MIN_MISS_RATE_ABSOLUTE)
          next if label.nil?

          Anomaly.new(
            staff: staff,
            metric: :first_contact_delay_30m_miss,
            value: miss_rate,
            baseline: median,
            deviation_label: label,
            context: { window_days: (@window / 1.day).to_i }
          )
        end
      end

      # Aggregate StaffMetric over window per staff. Возвращает только staff
      # с >= MIN_LEADS_FOR_FIRST_CONTACT leads (баselineable).
      def staff_first_contact_miss_map
        range = (@today - @window)..@today
        metrics = StaffMetric.for_period(range)

        sums = metrics.group(:staff_id).pluck(
          :staff_id,
          Arel.sql('SUM(leads_assigned)'),
          Arel.sql('SUM(leads_first_contact_in_30m)')
        )

        result = {}
        sums.each do |staff_id, assigned, in_30m|
          assigned = assigned.to_i
          in_30m   = in_30m.to_i
          next if assigned < MIN_LEADS_FOR_FIRST_CONTACT

          staff = TelegramUser.find_by(id: staff_id, status: 'active')
          next if staff.nil?

          # miss_rate = 1 - hit_rate. Higher = worse.
          miss_rate = 1.0 - (in_30m.to_f / assigned)
          result[staff] = miss_rate
        end
        result
      end

      # === Метрика 3: completion_rate_drop (per-staff longitudinal) ===
      # НЕ cross-staff. Сравниваем staff-сам-с-собой: last 7d vs prior 14d.
      # Triggers если completion_rate упал на >= MIN_DROP_PP percentage points.

      MIN_PRIOR_SAMPLES = 10 # дней в prior window
      MIN_CURRENT_SAMPLES = 3 # дней в current window
      MIN_DROP_PP = 0.20     # 20 процентных пунктов

      def detect_completion_rate_drop
        current_range = (@today - 7.days)..@today
        prior_range   = (@today - 21.days)..(@today - 8.days)

        anomalies = []
        TelegramUser.active.find_each do |staff|
          prior_rate = period_completion_rate(staff, prior_range, MIN_PRIOR_SAMPLES)
          next if prior_rate.nil?

          current_rate = period_completion_rate(staff, current_range, MIN_CURRENT_SAMPLES)
          next if current_rate.nil?

          drop = prior_rate - current_rate
          next if drop < MIN_DROP_PP

          anomalies << Anomaly.new(
            staff: staff,
            metric: :completion_rate_drop,
            value: current_rate,
            baseline: prior_rate,
            deviation_label: drop_label_for(drop),
            context: { drop_pp: (drop * 100).round(0) }
          )
        end
        anomalies
      end

      # Aggregate StaffMetric для staff в range. Возвращает nil если samples
      # < min_samples или нет tasks_assigned. Иначе — Float 0..1.
      def period_completion_rate(staff, range, min_samples)
        metrics = StaffMetric.for_staff(staff).for_period(range)
        samples = metrics.count
        return nil if samples < min_samples

        assigned, completed = metrics.pick(
          Arel.sql('SUM(tasks_assigned)'),
          Arel.sql('SUM(tasks_completed)')
        )
        assigned = assigned.to_i
        completed = completed.to_i
        return nil if assigned.zero?

        completed.to_f / assigned
      end

      # === Математика ===

      def median_of(values)
        return 0.0 if values.empty?

        sorted = values.sort
        mid = sorted.size / 2
        sorted.size.odd? ? sorted[mid] : ((sorted[mid - 1] + sorted[mid]) / 2.0)
      end

      # Median Absolute Deviation. Robust scale estimator.
      def mad_of(values, median)
        return 0.0 if values.empty?

        deviations = values.map { |v| (v - median).abs }
        median_of(deviations)
      end

      # Iglewicz & Hoaglin (1993) modified Z-Score using MAD.
      # 0.6745 — scale factor (1/Φ⁻¹(0.75)) для consistency с standard normal.
      def modified_z_score(value, median, mad)
        return 0.0 if mad.zero?

        ((value - median).abs * 0.6745 / mad)
      end

      # Возвращает deviation_label (String) если value — outlier; nil иначе.
      # Edge case: MAD=0 (все healthy на одной точке). В этом случае z посчитать
      # нельзя, но если value значительно выше median (минимум на 2× absolute
      # threshold), это конкретный outlier — отмечаем как «значительное».
      #
      # @param value [Float] метрика проверяемого staff
      # @param median [Float] baseline команды
      # @param mad [Float] разброс команды (median absolute deviation)
      # @param min_abs [Float] absolute threshold метрики (нижняя планка noise)
      def outlier_label(value, median, mad, min_abs)
        if mad.zero?
          gap = value - median
          return 'значительное' if gap >= (2 * min_abs)
          return 'существенное' if gap >= min_abs

          nil
        else
          z = modified_z_score(value, median, mad)
          z > MAD_THRESHOLD ? deviation_label_for(z) : nil
        end
      end

      # Лейбл отклонения для message. Без сленга — «значительное / существенное».
      def deviation_label_for(z_score)
        if z_score > 5.0
          'значительное'
        elsif z_score > MAD_THRESHOLD
          'существенное'
        else
          'умеренное'
        end
      end

      def drop_label_for(drop)
        if drop >= 0.40
          'значительное'
        elsif drop >= 0.25
          'существенное'
        else
          'заметное'
        end
      end
    end
  end
end
