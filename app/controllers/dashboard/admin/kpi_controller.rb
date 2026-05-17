# frozen_string_literal: true

module Dashboard
  module Admin
    # Phase 7.6 — KPI dashboard для директоров АН.
    # Table per-staff × 12 metrics + period filter (today/week/month/quarter).
    # Computed on-the-fly из StaffMetric (daily snapshots).
    class KpiController < Dashboard::BaseController
      before_action :require_admin!

      PERIOD_OPTIONS = {
        'today' => 0..0,
        'week' => 0..7,
        'month' => 0..30,
        'quarter' => 0..90
      }.freeze

      def index
        @period = params[:period].presence_in(PERIOD_OPTIONS.keys) || 'week'
        range_back = PERIOD_OPTIONS[@period]
        @date_range = (Date.current - range_back.end.days)..(Date.current - range_back.begin.days)

        @rows = build_rows
        @agency_totals = aggregate_rows(@rows)
      end

      private

      def build_rows
        TelegramUser.assignable.order(:tg_username).map do |staff|
          metrics = StaffMetric.for_staff(staff).for_period(@date_range).to_a
          {
            staff: staff,
            tasks_assigned: metrics.sum(&:tasks_assigned),
            tasks_completed: metrics.sum(&:tasks_completed),
            tasks_on_time: metrics.sum(&:tasks_on_time),
            tasks_overdue: metrics.sum(&:tasks_overdue),
            avg_completion_min: avg_completion_min(metrics),
            questions_asked: metrics.sum(&:questions_asked),
            leads_assigned: metrics.sum(&:leads_assigned),
            leads_first_contact_in_30m: metrics.sum(&:leads_first_contact_in_30m),
            leads_converted: metrics.sum(&:leads_converted),
            suspicious_completions: metrics.sum(&:suspicious_completions),
            documents_uploaded: metrics.sum(&:documents_uploaded)
          }
        end
      end

      def avg_completion_min(metrics)
        weighted = metrics.sum { |m| m.avg_completion_time_sec * m.tasks_completed }
        total    = metrics.sum(&:tasks_completed)
        return 0 if total.zero?

        (weighted.to_f / total / 60).round
      end

      def aggregate_rows(rows)
        keys = [:tasks_assigned, :tasks_completed, :tasks_on_time, :tasks_overdue, :questions_asked, :leads_assigned,
                :leads_first_contact_in_30m, :leads_converted, :suspicious_completions, :documents_uploaded]
        keys.index_with { |k| rows.sum { |r| r[k] } }
      end
    end
  end
end
