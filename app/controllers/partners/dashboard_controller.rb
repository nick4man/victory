# frozen_string_literal: true

# Phase 3b — partner portal dashboard. Read-only view of own referrals
# (filtered by partner_agency_id from session). Partner sees:
#   - Counts per status
#   - List of recent referrals (paginated)
#   - Estimated commission pending vs earned
#
# Edit actions (forward / close) — admin-only. Partner can only see.
# Future enhancement (Phase 3c): partner-side «confirm received», «mark
# closed» через limited actions с admin approval.
module Partners
  class DashboardController < ApplicationController
    before_action :require_partner_login

    def index
      base = Referral.where(partner_agency_id: @partner_agency.id).includes(:external_listing, :inquiry)
      @counts = {
        all:         base.count,
        pending:     base.pending.count,
        forwarded:   base.forwarded.count,
        in_progress: base.in_progress.count,
        closed_won:  base.closed_won.count,
        closed_lost: base.closed_lost.count
      }
      @earned   = base.closed_won.sum(:final_commission_amount).to_f
      @pending  = base.open.sum(&:estimated_commission).to_f

      scope = params[:status].present? ? base.where(status: params[:status]) : base
      @referrals = scope.order(created_at: :desc).page(params[:page]).per(50)
    end

    private

    def require_partner_login
      @partner_agency = PartnerAgency.find_by(id: session[:partner_agency_id])
      return if @partner_agency && @partner_agency.status == 'active'

      session.delete(:partner_agency_id)
      redirect_to partners_login_path, alert: 'Войдите в портал партнёра.'
    end
  end
end
