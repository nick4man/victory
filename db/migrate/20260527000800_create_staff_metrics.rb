# frozen_string_literal: true

# Phase 7.6 — Daily KPI snapshot per TelegramUser.
# Pre-computed для quick dashboard + historical тренды.
# Source-of-truth: Kpi::StaffSnapshotJob (cron 23:55).
#
# Derived в view (НЕ хранятся):
#   • Completion rate     = tasks_completed / tasks_assigned
#   • On-time rate        = tasks_on_time   / tasks_completed
#   • Question dependency = questions_asked / tasks_completed
#   • Conversion rate     = leads_converted / leads_assigned (90d attribution)
class CreateStaffMetrics < ActiveRecord::Migration[7.1]
  def change
    create_table :staff_metrics do |t|
      t.bigint  :staff_id, null: false # FK логический → telegram_users
      t.date    :date,     null: false

      # Task metrics
      t.integer :tasks_assigned,           null: false, default: 0
      t.integer :tasks_completed,          null: false, default: 0
      t.integer :tasks_on_time,            null: false, default: 0
      t.integer :tasks_overdue,            null: false, default: 0
      t.integer :avg_completion_time_sec,  null: false, default: 0
      t.integer :suspicious_completions,   null: false, default: 0

      # Q&A metric (Phase 7.5)
      t.integer :questions_asked,          null: false, default: 0

      # Lead pipeline metrics (Phase 2/3)
      t.integer :leads_assigned,                null: false, default: 0
      t.integer :leads_first_contact_in_30m,    null: false, default: 0
      t.integer :leads_converted,               null: false, default: 0

      # NC document metric (Phase 7.8a)
      t.integer :documents_uploaded, null: false, default: 0

      t.timestamps
    end

    add_index :staff_metrics, [:staff_id, :date], unique: true
    add_index :staff_metrics, :date
  end
end
