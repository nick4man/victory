# frozen_string_literal: true

module Admin
  # Phase 3 MLS/YRL — управление партнёрскими агентствами для commission tracking.
  # Token-guarded через AdminTokenAuth (Devise off).
  #
  # Use-cases:
  #   - первоначальное создание агентств (например, ЦАН Рязань) до того
  #     как первый Referral создастся через Referrals::AutoCreator
  #   - корректировка default_commission_rate без `rails console`
  #   - blocked-flag для агентств с disputed commissions (auto_creator
  #     откажется создавать Referral)
  #   - заведение `feed_source_key` для матча с ExternalListing.source_id
  #
  # Routes:
  #   GET    /admin/partner_agencies          → index (фильтр по status)
  #   GET    /admin/partner_agencies/new      → new
  #   POST   /admin/partner_agencies          → create
  #   GET    /admin/partner_agencies/:id/edit → edit
  #   PATCH  /admin/partner_agencies/:id      → update
  #   DELETE /admin/partner_agencies/:id      → destroy (soft-delete)
  class PartnerAgenciesController < ApplicationController
    include AdminTokenAuth
    layout 'application'

    before_action :set_partner_agency, only: %i[edit update destroy]

    def index
      @status = params[:status].presence
      scope = PartnerAgency.order(:name)
      scope = scope.where(status: @status) if @status && PartnerAgency::STATUSES.include?(@status)
      @partner_agencies = scope
      @counts = {
        all:      PartnerAgency.count,
        active:   PartnerAgency.where(status: 'active').count,
        inactive: PartnerAgency.where(status: 'inactive').count,
        blocked:  PartnerAgency.where(status: 'blocked').count
      }
    end

    def new
      @partner_agency = PartnerAgency.new(status: 'active', default_commission_rate: 0.30)
    end

    def create
      @partner_agency = PartnerAgency.new(partner_agency_params)
      if @partner_agency.save
        redirect_to admin_partner_agencies_path, notice: "Агентство «#{@partner_agency.name}» создано."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit; end

    def update
      if @partner_agency.update(partner_agency_params)
        redirect_to admin_partner_agencies_path, notice: 'Сохранено.'
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @partner_agency.destroy
      redirect_to admin_partner_agencies_path,
                  notice: "Агентство «#{@partner_agency.name}» удалено (soft-delete)."
    end

    private

    def set_partner_agency
      @partner_agency = PartnerAgency.find(params[:id])
    end

    # Slug — нормализуем (lowercase, replace spaces with `-`) перед валидацией.
    # commission_rate приходит как процент (30) — конвертим в 0.30.
    def partner_agency_params
      raw = params.require(:partner_agency).permit(
        :name, :slug, :status, :default_commission_rate_percent,
        :contact_email, :contact_phone, :contact_person,
        :feed_source_key, :settlement_terms, :notes
      )

      percent = raw.delete(:default_commission_rate_percent)
      if percent.present?
        decimal = percent.to_f / 100.0
        raw[:default_commission_rate] = decimal.clamp(0.0, 1.0)
      end

      slug_in = raw[:slug].to_s.strip.downcase.tr(' ', '-')
      raw[:slug] = slug_in if slug_in.present?
      raw
    end
  end
end
