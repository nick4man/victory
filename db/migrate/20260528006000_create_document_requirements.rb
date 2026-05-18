# frozen_string_literal: true

# Phase 4A — DocumentRequirement: per-deal checklist of required documents.
#
# Architecture:
#   • Polymorphic anchor (lead_event OR property) — property может требовать
#     appraisal/EGRN до того как есть active lead
#   • 15 kinds covering РФ real-estate document taxonomy
#   • 6-state lifecycle (not_requested → ... → approved | rejected)
#   • Per-kind SLA (passport=1day, EGRN=5days, contract=14days) — см. model const
#   • Dependency graph (DEPENDS_ON) — passport_main triggers passport_registration
#   • Link to A6 ClientDocument (Phase 4G) — auto-match OCR'd uploads
#   • Soft-delete via deleted_at + composite unique (lead_event_id, kind, deleted_at)
class CreateDocumentRequirements < ActiveRecord::Migration[7.1]
  def change
    create_table :document_requirements do |t|
      t.references :lead_event, foreign_key: true, null: true, index: true
      t.references :property, foreign_key: true, null: true, index: true

      t.string :kind, null: false
      t.string :status, null: false, default: 'not_requested'

      # Lifecycle timestamps — каждый state имеет точку входа для SLA + audit.
      t.datetime :requested_at
      t.datetime :received_at
      t.datetime :verified_at
      t.datetime :approved_at
      t.datetime :rejected_at

      # Actor refs — кто request'нул / verified / approved.
      t.bigint :requested_by_id, null: true, index: true # FK логический → telegram_users
      t.bigint :verified_by_id,  null: true, index: true
      t.bigint :approved_by_id,  null: true, index: true

      # Phase 4G — auto-match к загруженному client document (A6 intake).
      t.references :received_via_client_document,
                   foreign_key: { to_table: :client_documents },
                   null: true, index: { name: 'idx_doc_req_via_cd' }

      # Per-kind SLA may be customised — overrides default DocumentRequirement::SLA_SECONDS[kind].
      t.integer :sla_seconds, null: true

      # Reminder tracking (Phase 4F).
      t.datetime :last_reminder_at
      t.integer :reminder_count, default: 0, null: false

      # Free-form notes от agent (e.g., «копия принёс лично», «ждём от нотариуса»).
      t.text :note

      # Free-form metadata jsonb (extensible — composite-document refs, OCR data, rejection reason).
      t.jsonb :metadata, default: {}, null: false

      t.datetime :deleted_at, index: true

      t.timestamps
    end

    # Composite unique index: один DocumentRequirement каждого kind на lead_event
    # (партиал на NULL deleted_at — позволяет re-create после soft-delete).
    add_index :document_requirements,
              [:lead_event_id, :kind],
              unique: true,
              where: 'deleted_at IS NULL AND lead_event_id IS NOT NULL',
              name: 'idx_doc_req_unique_lead_kind'

    add_index :document_requirements,
              [:property_id, :kind],
              unique: true,
              where: 'deleted_at IS NULL AND property_id IS NOT NULL AND lead_event_id IS NULL',
              name: 'idx_doc_req_unique_property_kind'

    # Frequent query: open requirements per lead (для /doc status + reminder cron).
    add_index :document_requirements,
              [:lead_event_id, :status],
              where: 'deleted_at IS NULL',
              name: 'idx_doc_req_lead_status'

    # SLA-reminder hot query: open + requested_at older than 24h.
    add_index :document_requirements,
              [:status, :requested_at],
              where: "deleted_at IS NULL AND status IN ('requested', 'received')",
              name: 'idx_doc_req_sla_assessor'
  end
end
