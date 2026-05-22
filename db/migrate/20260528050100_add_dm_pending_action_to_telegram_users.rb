# frozen_string_literal: true

# Iter 60 — generic conversation state для multi-turn DM-сценариев.
# Первое применение: photo disposition (photo received → ждём выбор cloud/staff
# → если cloud → ждём target → выполняем). Также применимо для будущих flow:
# /promote confirm, /deactivate confirm, lead reassign chain.
#
# Schema:
#   { "type":"photo_disposition", "expires_at":"2026-05-22T18:00:00Z",
#     "step":"choose_destination|choose_cloud_target|describe_task",
#     "data":{ "file_id":"...", "target_kind":"general|lead|staff", ... } }
#
# TTL обычно 10 мин. Expired → cleared при следующем pending_action read.
class AddDmPendingActionToTelegramUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :telegram_users, :dm_pending_action, :jsonb, default: {}, null: false
    add_index  :telegram_users, :dm_pending_action, using: :gin
  end
end
