# frozen_string_literal: true

# Локальные задачи по сделке (TG-бот /task команда).
# Topnlab API не предоставляет ресурс задач — храним локально, дедлайн ещё
# пробрасывается в fc_next_action_at кастомного поля CRM (patch_entity).
# Связь с CRM через topnlab_id + topnlab_type ('realty' | 'order').
# Связь с лидом — опционально через lead_event_id (если задача поставлена reply на якорь).
class CreateTasks < ActiveRecord::Migration[7.1]
  def change
    create_table :tasks do |t|
      t.bigint :topnlab_id                                            # id связанной сущности в Topnlab
      t.string :topnlab_type                                          # 'realty' | 'order'
      t.references :lead_event, foreign_key: true, index: true
      t.references :assignee,   foreign_key: { to_table: :telegram_users }, index: true
      t.references :created_by, foreign_key: { to_table: :telegram_users }, index: true

      t.string   :title,        null: false
      t.datetime :due_at
      t.string   :status,       null: false, default: 'open'          # 'open' | 'done' | 'canceled'
      t.bigint   :tg_message_id                                       # message_id команды /task в TG (для аудита)

      t.datetime :deleted_at,   index: true                           # soft-delete (см. CLAUDE.md правило 1)
      t.timestamps
    end

    add_index :tasks, %i[assignee_id status due_at]
    add_index :tasks, %i[topnlab_id topnlab_type]
    add_index :tasks, :status
  end
end
