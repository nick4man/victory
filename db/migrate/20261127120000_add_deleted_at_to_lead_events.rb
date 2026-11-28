# frozen_string_literal: true

# Issue #277 — soft-delete лида из карточки дашборда (правило #1 AGENTS.md:
# deleted_at + default_scope, никакого destroy). Удалённый лид исчезает из
# выборок .real, списков дашборда и блокируется для выгрузки в CRM.
class AddDeletedAtToLeadEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :lead_events, :deleted_at, :datetime
    add_index :lead_events, :deleted_at, name: 'idx_lead_events_deleted_at'
  end
end
