# frozen_string_literal: true

# Audit table for Topnlab importer runs. Each TopnlabSyncJob writes one row
# at the start of its sweep and updates the counters on completion. Lets
# the admin /admin/topnlab_status page show "last run 5 min ago, ingested
# 99, archived 84" without having to mine Rails logs.
class CreateTopnlabSyncRuns < ActiveRecord::Migration[7.1]
  def change
    create_table :topnlab_sync_runs do |t|
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.integer  :ids_seen,        default: 0
      t.integer  :upserted,        default: 0
      t.integer  :archived,        default: 0
      t.integer  :photos_pending,  default: 0
      t.text     :errors                  # joined error strings (truncated)
      t.string   :status, default: 'running'  # running | success | partial | failed
      t.timestamps
    end

    add_index :topnlab_sync_runs, :started_at
    add_index :topnlab_sync_runs, :status
  end
end
