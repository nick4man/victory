# frozen_string_literal: true

# B2 — Foreign investment audit. Lightweight wrapper над существующим
# `Valuations::InvestmentController` flow с двумя отличиями:
#   1. I18n.locale = :en на все actions (EN templates + en.yml audit.*)
#   2. `PropertyValuation.metadata['audit_locale']='en'` + 'secondary_currency'='USD'
#      → InvestmentAuditJob#enrich_for_foreign_audit генерирует
#         visa-chapter + snapshot currency rates
#      → AuditPdfGenerator переключается в EN режим + вставляет
#         VisaResidencyPage + ConversionTablePage перед Glossary.
#
# Auth: anonymous (visitor flow). Rate-limited per IP (Redis).
# Templates: app/views/foreign/audits/{new,processing,show}.html.erb (EN).
class Foreign::AuditsController < ApplicationController
  RATE_LIMIT = { count: 5, window: 1.hour }.freeze

  layout 'application'

  before_action :force_en_locale

  def new
    @valuation = PropertyValuation.new(
      audit_mode: 'investment',
      deal_type: 'sale',
      property_type: 'apartment'
    )
    @rates = CurrencyRatesService.call
  end

  def create
    if rate_limited?
      flash[:alert] = t('foreign_audit.errors.rate_limit')
      redirect_to new_foreign_audit_path and return
    end

    @valuation = PropertyValuation.new(audit_params.merge(
      audit_mode: 'investment',
      status: 'pending',
      ip_address: request.remote_ip,
      user_agent: request.user_agent,
      metadata: {
        'audit_locale'       => 'en',
        'secondary_currency' => 'USD',
        'foreign_audit'      => true
      }
    ))

    if @valuation.save
      InvestmentAuditJob.perform_later(@valuation.id)
      redirect_to foreign_audit_path(@valuation.token)
    else
      @rates = CurrencyRatesService.call
      render :new, status: :unprocessable_entity
    end
  end

  def show
    @valuation = find_valuation!
    @audit       = @valuation.evaluation_data&.dig('audit')
    @monte_carlo = @valuation.evaluation_data&.dig('monte_carlo')
    @rates       = resolve_rates(@valuation)
    # Pending → render processing template (auto-poll via JS).
    if @valuation.pending?
      render :processing and return
    end
    if @valuation.failed?
      render :failed and return
    end
    # Completed — render show (EN result page).
  end

  # JSON polling fallback for processing page.
  def status
    valuation = find_valuation!
    render json: {
      status:  valuation.status,
      verdict: valuation.evaluation_data&.dig('audit', 'verdict'),
      error:   valuation.evaluation_data&.dig('error', 'body')
    }
  end

  def download_pdf
    valuation = find_valuation!
    unless valuation.completed? && valuation.evaluation_data&.dig('audit').present?
      redirect_to foreign_audit_path(valuation.token),
                  alert: t('foreign_audit.errors.not_ready') and return
    end

    pdf_data = AuditPdfGenerator.call(valuation, locale: :en)
    send_data pdf_data,
              filename: "investment-audit-#{valuation.token}.pdf",
              type: 'application/pdf',
              disposition: 'attachment'
  rescue StandardError => e
    Rails.logger.warn("[Foreign::AuditsController#download_pdf] #{e.class}: #{e.message}")
    redirect_to foreign_audit_path(valuation.token),
                alert: t('foreign_audit.errors.pdf_failed')
  end

  private

  def force_en_locale
    I18n.locale = :en
  end

  def find_valuation!
    PropertyValuation.find_by!(token: params[:id] || params[:token])
  end

  # Snapshot курсов из metadata если есть (PDF не плавает между downloads),
  # иначе live из CurrencyRatesService.
  def resolve_rates(valuation)
    cached = valuation.metadata&.[]('exchange_rates')
    if cached.is_a?(Hash) && cached['usd'].present?
      cached.symbolize_keys
    else
      CurrencyRatesService.call
    end
  end

  def audit_params
    params.require(:property_valuation).permit(
      :property_type, :deal_type, :address, :total_area, :rooms,
      :floor, :total_floors, :building_year, :building_type,
      :property_condition, :estimated_price, :name, :email, :phone
    )
  end

  # Mirror'ит Valuations::InvestmentController#rate_limited?
  # Redis DB 1, namespace foreign_audit:rate:*
  def rate_limited?
    return false unless defined?(Redis)

    key = "foreign_audit:rate:#{request.remote_ip}"
    redis = Redis.new(url: ENV.fetch('REDIS_URL', 'redis://redis:6379/1'))
    count = redis.incr(key)
    redis.expire(key, RATE_LIMIT[:window].to_i) if count == 1
    count > RATE_LIMIT[:count]
  rescue Redis::BaseError => e
    Rails.logger.warn("[Foreign::AuditsController] rate-limit Redis error: #{e.message}")
    false
  end
end
