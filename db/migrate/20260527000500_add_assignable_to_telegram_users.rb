# frozen_string_literal: true

# Phase 7.3+ — Opt-out флаг для пользователей которые не должны появляться
# в picker'е [👤 Назначить] (admin/dev, не полевые агенты).
#
# По умолчанию assignable=true для всех — сохраняет текущее поведение.
# Опт-аут для конкретных users через rails console / future команду
# `/unassignable` (TODO).
class AddAssignableToTelegramUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :telegram_users, :assignable, :boolean, null: false, default: true
    add_index  :telegram_users, :assignable
  end
end
