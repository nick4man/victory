# frozen_string_literal: true

# Phase 3 — поле для дедупа SLA-пингов по задачам.
# TasksWatchdogJob обновляет это поле при каждом DM «📌 Просрочена задача»,
# чтобы не спамить агента одной и той же задачей каждые 5 мин.
class AddLastPingedAtToTasks < ActiveRecord::Migration[7.1]
  def change
    add_column :tasks, :last_pinged_at, :datetime
    add_index  :tasks, :last_pinged_at
  end
end
