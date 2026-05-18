# frozen_string_literal: true

# Phase 9 Iter 7 — Track CRM sync failures для observability.
#
# transfer_client + patch_entity могут падать silently (network blip, rate-limit,
# unknown fc_* field). Раньше — log warn + продолжали local assignment, CRM
# не знал. Теперь — флаг для retry job и admin visibility.
class AddCrmSyncFailedToLeadEvents < ActiveRecord::Migration[7.1]
  def change
    add_column :lead_events, :crm_sync_failed, :boolean, null: false, default: false
    add_column :lead_events, :crm_sync_last_error, :string
    add_index :lead_events, :crm_sync_failed, where: 'crm_sync_failed = TRUE',
                                              name: 'idx_lead_events_crm_sync_failed'
  end
end
