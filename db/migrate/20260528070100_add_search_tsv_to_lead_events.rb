# frozen_string_literal: true

# Phase 15 — FTS на лидах для search_all_leads tool.
# Сейчас lookup_lead ищет только по name/phone/crm_id точным match'ем.
# Director'у нужно «найди лиды по Канищево» — это search по metadata.summary,
# metadata.name, и текстам из metadata.notes[].text.
#
# Generated column на JSONB полях — extracted в tsvector с russian dict.
# Stored = пересчёт при INSERT/UPDATE автоматически (никакой sync-логики).
class AddSearchTsvToLeadEvents < ActiveRecord::Migration[7.1]
  def up
    execute <<~SQL
      ALTER TABLE lead_events
        ADD COLUMN search_tsv tsvector
        GENERATED ALWAYS AS (
          to_tsvector(
            'russian',
            COALESCE(metadata->>'summary', '') || ' ' ||
            COALESCE(metadata->>'name', '') || ' ' ||
            COALESCE((metadata->'notes')::text, '')
          )
        ) STORED;
    SQL

    execute <<~SQL
      CREATE INDEX idx_lead_events_search_tsv
        ON lead_events USING gin(search_tsv);
    SQL
  end

  def down
    execute 'DROP INDEX IF EXISTS idx_lead_events_search_tsv;'
    execute 'ALTER TABLE lead_events DROP COLUMN IF EXISTS search_tsv;'
  end
end
