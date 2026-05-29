# frozen_string_literal: true

# Phase 7.4 — Один pinned message в #ДИСПЕТЧЕРСКАЯ за день обновляется
# editMessageText в течение дня. На следующий день — новый pinned, старый
# unpin'нут через DigestCleanupJob.
#
# Уникальность по date (один digest на сутки в одном chat). Soft-delete если
# вдруг надо переcоздать без удаления audit-trail.
class CreateDailyDigests < ActiveRecord::Migration[7.1]
  def change
    create_table :daily_digests do |t|
      t.date     :date,            null: false
      t.bigint   :tg_chat_id,      null: false
      t.bigint   :tg_thread_id                       # nil для General
      t.bigint   :tg_message_id,   null: false       # id pinned message
      t.string   :topic_key,       default: 'dispatcher'
      t.datetime :posted_at,       null: false
      t.datetime :archived_at                        # unpin'нут (DigestCleanupJob)
      t.integer  :tasks_count,     default: 0        # snapshot для quick stats
      t.integer  :done_count,      default: 0
      t.datetime :deleted_at,      index: true
      t.timestamps
    end

    add_index :daily_digests, [:date, :tg_chat_id], unique: true,
                                                    where: 'deleted_at IS NULL',
                                                    name: 'idx_daily_digests_active_per_day_chat'
    add_index :daily_digests, :date
  end
end
