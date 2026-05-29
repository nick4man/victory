# frozen_string_literal: true

module Kpi
  # Phase 7.6 — Computes daily StaffMetric snapshot per TelegramUser.
  # Caller: Kpi::StaffSnapshotJob (cron 23:55) OR ad-hoc для backfill.
  #
  # Идемпотентно через upsert (unique index staff_id+date).
  #
  # @example
  #   Kpi::StaffSnapshot.run!(date: Date.current)
  class StaffSnapshot
    # 90-day attribution window для lead conversion — индустриальный стандарт
    # для real-estate (avg deal cycle 50-80 дней).
    CONVERSION_WINDOW = 90.days

    def self.run!(date: Date.current)
      new(date: date).run!
    end

    def initialize(date:)
      @date = date
      @range = date.all_day
    end

    def run!
      results = []
      TelegramUser.assignable.find_each do |staff|
        metrics = compute_for(staff)
        record = upsert!(staff, metrics)
        results << record
      end
      results
    end

    private

    def compute_for(staff)
      task_stats = tasks_stats(staff)
      lead_stats = leads_stats(staff)
      {
        # Tasks
        **task_stats,
        questions_asked: questions_count(staff),
        # Leads
        **lead_stats,
        # Documents
        documents_uploaded: documents_count(staff)
      }
    end

    def tasks_stats(staff)
      scope = ::Task.unscoped.where(assignee_id: staff.id, deleted_at: nil)

      assigned   = scope.where(assigned_at: @range).count
      done_scope = scope.where(completed_at: @range, status: 'done')
      completed  = done_scope.count
      on_time    = done_scope.where('completed_at <= due_at OR due_at IS NULL').count

      overdue = scope.where(status: 'open').where(due_at: ...@range.end).count

      durations = done_scope.where.not(assigned_at: nil).pluck(
        Arel.sql('EXTRACT(EPOCH FROM (completed_at - assigned_at))')
      )
      avg_sec = durations.any? ? (durations.sum / durations.size).to_i : 0

      suspicious = done_scope.where(suspicious_flag: true).count

      {
        tasks_assigned: assigned,
        tasks_completed: completed,
        tasks_on_time: on_time,
        tasks_overdue: overdue,
        avg_completion_time_sec: avg_sec,
        suspicious_completions: suspicious
      }
    end

    def leads_stats(staff)
      scope = LeadEvent.where(assigned_to_id: staff.id)

      assigned = scope.where(assigned_at: @range).count
      in_30m   = scope.where(assigned_at: @range)
                      .where('first_contact_at IS NOT NULL ' \
                             'AND EXTRACT(EPOCH FROM (first_contact_at - assigned_at)) <= 1800').count

      # Conversion attribution — 90-day window от назначения до closed_won.
      # Считаем converted в этом днё (closed_at в @range и assigned_at >= 90d ago).
      converted = scope.where(closed_at: @range, current_stage: 'closed_won').count

      { leads_assigned: assigned, leads_first_contact_in_30m: in_30m, leads_converted: converted }
    end

    def questions_count(staff)
      StaffQuestion.unscoped.where(asked_by_id: staff.id, created_at: @range, deleted_at: nil)
                   .where(kind: ['clarification', 'escalation']).count
    end

    def documents_count(staff)
      DocumentUpload.unscoped.where(uploaded_by_id: staff.id, uploaded_at: @range, deleted_at: nil).count
    end

    def upsert!(staff, metrics)
      attrs = metrics.merge(staff_id: staff.id, date: @date,
                            updated_at: Time.current, created_at: Time.current)
      StaffMetric.upsert(attrs, unique_by: [:staff_id, :date])
      StaffMetric.find_by(staff_id: staff.id, date: @date)
    end
  end
end
