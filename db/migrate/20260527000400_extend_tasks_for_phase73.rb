# frozen_string_literal: true

# Phase 7.3 — Расширение Task для полного lifecycle с time-attribution и
# multi-modal completion ack.
#
# New columns:
#   assigned_at      — момент создания/назначения (raw создания Task запиcи)
#   notified_at      — момент когда DM с задачей улетел assignee
#   first_acked_at   — первый ack (button / command / reaction)
#   started_at       — assignee нажал [▶ В работе]
#   completed_at     — финальная отметка выполнено
#   acked_method     — string enum: button | command | reaction
#   task_batch_id    — FK на TaskBatch (Phase 7.2) — для аналитики voice-batched задач
#   priority         — string enum: low | normal | high | urgent
#   kind             — string enum: call | show | document | admin | other
#   suspicious_flag  — boolean: true если completed_at - assigned_at < 60s
#
# Index для KPI snapshot (Phase 7.6) — by assignee + completed window.
class ExtendTasksForPhase73 < ActiveRecord::Migration[7.1]
  def change
    change_table :tasks, bulk: true do |t|
      t.datetime :assigned_at
      t.datetime :notified_at
      t.datetime :first_acked_at
      t.datetime :started_at
      t.datetime :completed_at
      t.string   :acked_method # button|command|reaction
      t.bigint   :task_batch_id                              # FK логический → task_batches
      t.string   :priority, null: false, default: 'normal'   # low|normal|high|urgent
      t.string   :kind,     null: false, default: 'other'    # call|show|document|admin|other
      t.boolean  :suspicious_flag, null: false, default: false
    end

    # Бэкфилл assigned_at для существующих записей (если есть).
    execute <<~SQL.squish
      UPDATE tasks SET assigned_at = created_at WHERE assigned_at IS NULL
    SQL

    add_index :tasks, [:assignee_id, :completed_at]
    add_index :tasks, :task_batch_id
    add_index :tasks, :priority
    add_index :tasks, :kind
    add_index :tasks, :suspicious_flag, where: 'suspicious_flag = TRUE'
  end
end
