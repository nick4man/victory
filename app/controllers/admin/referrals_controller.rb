# frozen_string_literal: true

module Admin
  # Phase 3 MLS/YRL — referral lifecycle management. AdminTokenAuth-gated.
  #
  # Flow:
  #   1. Inquiry на /external-listings/:id → Referrals::AutoCreator
  #      → Referral(status: pending)
  #   2. Admin reviews index → decides: forward / close_lost / mark in_progress
  #   3. Closed_won — admin вводит final_commission_amount
  #
  # Routes (config/routes.rb):
  #   GET  /admin/referrals              → index (filter by status, agency)
  #   GET  /admin/referrals/:id          → show (timeline + actions)
  #   POST /admin/referrals/:id/forward       → forward!
  #   POST /admin/referrals/:id/close_won     → close_won! (with amount)
  #   POST /admin/referrals/:id/close_lost    → close_lost! (with reason)
  #   GET  /admin/referrals/settlements  → aggregated per-agency
  class ReferralsController < ApplicationController
    include AdminTokenAuth
    layout 'application'

    before_action :set_referral, only: %i[show forward close_won close_lost]

    def index
      scope = Referral.includes(:inquiry, :partner_agency, :external_listing)
      scope = scope.where(status: params[:status])               if params[:status].present?
      scope = scope.where(partner_agency_id: params[:agency_id]) if params[:agency_id].present?

      @referrals = scope.order(created_at: :desc).page(params[:page]).per(50)
      @counts = referral_counts
      @agencies = PartnerAgency.order(:name)
    end

    def show; end

    # POST /admin/referrals/:id/forward — Передать партнёру через выбранный канал.
    def forward
      channel = params[:channel].presence || 'unknown'
      @referral.forward!(channel: channel, actor: 'admin')
      redirect_to admin_referral_path(@referral),
                  notice: "Лид передан партнёру #{@referral.partner_agency.name} (channel: #{channel})."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to admin_referral_path(@referral), alert: "Ошибка: #{e.message}"
    end

    # POST /admin/referrals/:id/close_won — Зафиксировать сделку closed_won с суммой.
    def close_won
      amount = params[:final_commission_amount].to_f
      if amount <= 0
        return redirect_to admin_referral_path(@referral),
                           alert: 'Укажите финальную сумму комиссии (> 0).'
      end

      @referral.close_won!(amount: amount, actor: 'admin')
      redirect_to admin_referral_path(@referral),
                  notice: "Сделка зафиксирована: #{ActionController::Base.helpers.number_with_delimiter(amount.to_i)} ₽."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to admin_referral_path(@referral), alert: "Ошибка: #{e.message}"
    end

    # POST /admin/referrals/:id/close_lost — Закрыть как lost с причиной.
    def close_lost
      reason = params[:reason].presence || 'не указана'
      @referral.close_lost!(reason: reason, actor: 'admin')
      redirect_to admin_referral_path(@referral), notice: 'Referral закрыт как lost.'
    rescue ActiveRecord::RecordInvalid => e
      redirect_to admin_referral_path(@referral), alert: "Ошибка: #{e.message}"
    end

    # GET /admin/referrals/settlements — Per-agency aggregations.
    def settlements
      @settlements = PartnerAgency.includes(:referrals).map do |agency|
        refs = agency.referrals
        {
          agency:      agency,
          pending:     refs.where(status: 'pending').count,
          forwarded:   refs.where(status: 'forwarded').count,
          in_progress: refs.where(status: 'in_progress').count,
          closed_won:  refs.where(status: 'closed_won').count,
          closed_lost: refs.where(status: 'closed_lost').count,
          earned_total:     refs.closed_won.sum(:final_commission_amount).to_f,
          pending_estimate: refs.open.includes(:external_listing).sum(&:estimated_commission)
        }
      end
    end

    private

    def set_referral
      @referral = Referral.includes(:inquiry, :partner_agency, :external_listing).find(params[:id])
    end

    def referral_counts
      base = Referral
      {
        all:         base.count,
        pending:     base.pending.count,
        forwarded:   base.forwarded.count,
        in_progress: base.in_progress.count,
        closed_won:  base.closed_won.count,
        closed_lost: base.closed_lost.count
      }
    end
  end
end
