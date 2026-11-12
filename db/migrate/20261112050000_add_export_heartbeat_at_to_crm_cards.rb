# frozen_string_literal: true

# Heartbeat живой попытки выгрузки: ставится вокруг каждого сетевого вызова
# CrmCards::Workflow → CrmCards::LeadExporter. Пока heartbeat свежий,
# CrmCard#export_stale? ложна и ручной «Повторить» откажет — вторая попытка
# (второй неидемпотентный importClient) стартует только после падения или
# зависания первой (ревью PR #210, блокер 1).
class AddExportHeartbeatAtToCrmCards < ActiveRecord::Migration[8.1]
  def change
    add_column :crm_cards, :export_heartbeat_at, :datetime
  end
end
