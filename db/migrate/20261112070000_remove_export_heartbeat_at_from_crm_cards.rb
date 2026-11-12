# frozen_string_literal: true

# Откат колонки export_heartbeat_at: сериализация владения попыткой выгрузки
# переехала на Postgres advisory lock (CrmCards::ExportLock), heartbeat как
# источник истины о живости не нужен (ревью PR #210, round 3).
class RemoveExportHeartbeatAtFromCrmCards < ActiveRecord::Migration[8.1]
  def change
    remove_column :crm_cards, :export_heartbeat_at, :datetime
  end
end
