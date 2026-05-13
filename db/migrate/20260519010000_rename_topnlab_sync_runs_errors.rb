# frozen_string_literal: true

# `errors` column name collides with ActiveRecord::Errors (every model has
# `#errors`), so the migration would not have produced a working model.
# Rename to `error_log`.
class RenameTopnlabSyncRunsErrors < ActiveRecord::Migration[7.1]
  def change
    rename_column :topnlab_sync_runs, :errors, :error_log
  end
end
