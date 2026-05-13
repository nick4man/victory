# frozen_string_literal: true

# One row per Topnlab importer sweep. See Topnlab::Importer#call —
# it brackets the work with `TopnlabSyncRun.start` + `#finish!(...)` so
# the admin status page can show recent activity at a glance.
class TopnlabSyncRun < ApplicationRecord
  STATUSES = %w[running success partial failed].freeze
  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(started_at: :desc) }
  scope :successful, -> { where(status: 'success') }

  def self.start
    create!(started_at: Time.current, status: 'running')
  end

  # Wrap the importer's `call` block. Updates counters + status when done.
  # Always returns the block's result so callers can keep the existing
  # return shape.
  def self.track
    run = start
    begin
      result = yield(run)
      run.finish!(result)
      result
    rescue StandardError => e
      run.update!(
        finished_at: Time.current,
        status: 'failed',
        error_log: "#{e.class}: #{e.message.to_s.truncate(500)}"
      )
      raise
    end
  end

  def finish!(result_hash)
    errs = Array(result_hash[:errors] || result_hash[:error_log])
    update!(
      finished_at:    Time.current,
      ids_seen:       result_hash[:ids_seen].to_i,
      upserted:       result_hash[:upserted].to_i,
      archived:       result_hash[:archived].to_i,
      photos_pending: result_hash[:photos_pending].to_i,
      error_log:      errs.join("\n").truncate(1000),
      status:         (errs.empty? ? 'success' : 'partial')
    )
  end

  def duration_seconds
    return nil unless finished_at && started_at

    (finished_at - started_at).to_f.round(1)
  end
end
