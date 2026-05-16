# frozen_string_literal: true

# Phase 7.1 — добавляем enum-роль (agent/manager/director/admin) для
# Director-voice intake авторизации. is_manager оставляем для backward-compat
# (legacy boolean используется в Sla::* + Commands::*::manager_only).
#
# Backfill convention:
#   is_manager=true  → role='manager'
#   is_manager=false → role='agent'
# Director-уровень (Оксана) проставляется отдельным rake task'ом или вручную.
class AddRoleToTelegramUsers < ActiveRecord::Migration[7.1]
  def up
    add_column :telegram_users, :role, :string, default: 'agent', null: false
    add_index  :telegram_users, :role

    # Бэкфилл — managers уже отделены через is_manager
    execute <<~SQL.squish
      UPDATE telegram_users
         SET role = 'manager'
       WHERE is_manager = TRUE
    SQL
  end

  def down
    remove_index  :telegram_users, :role
    remove_column :telegram_users, :role
  end
end
