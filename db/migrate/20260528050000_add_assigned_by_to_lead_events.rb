# frozen_string_literal: true

# Iter 59 — director self-audit: трекинг кто из staff назначил агента / направил
# лид в спец-топик. До фикса originator терялся: assigned_to + assigned_at в
# колонках, но кто это сделал — только в metadata['routing_history'][...]['by']
# (string mention) для /route и нигде для /assign. Делаем оба + FK для индексных
# SQL-запросов («какие лиды я назначил сегодня»), metadata дублируется (Iter 59
# выбор пользователя: belt-and-suspenders, FK + history-trail).
class AddAssignedByToLeadEvents < ActiveRecord::Migration[7.1]
  def change
    add_reference :lead_events, :assigned_by,
                  foreign_key: { to_table: :telegram_users }, null: true, index: true
    add_reference :lead_events, :routed_by,
                  foreign_key: { to_table: :telegram_users }, null: true, index: true
  end
end
