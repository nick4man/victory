# frozen_string_literal: true

module Admin
  # Health dashboard for the Topnlab importer. Shows recent sync runs and
  # the current published/archived balance so the operator can spot when
  # the cron stopped firing or started archiving en masse.
  class TopnlabStatusController < ApplicationController
    include AdminTokenAuth
    layout 'application'

    def index
      @runs = TopnlabSyncRun.recent.limit(30)
      @last = @runs.first
      @counts = {
        total:     Property.unscoped.where.not(external_id: nil).count,
        published: Property.unscoped.where(status: :active).where.not(published_at: nil).count,
        archived:  Property.unscoped.where(status: :archived).count,
        force:     Property.unscoped.where(force_publish: true).count
      }
    end
  end
end
