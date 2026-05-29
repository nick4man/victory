# frozen_string_literal: true

# Investment Audit — Phase 4 controller. Flow:
#
#   GET  /valuations/audit/new    → form (3 steps)
#   POST /valuations/audit        → create PropertyValuation(audit_mode:investment,
#                                   status:pending) + enqueue InvestmentAuditJob
#                                   → redirect to /:token loader page
#   GET  /valuations/audit/:token → loader if pending; result if completed
#   GET  /:token/status           → JSON poll fallback for the loader
#   GET  /:token/pdf              → proxy PDF stream from audit-engine
#
# Auth: anonymous (visitor flow). Submissions are rate-limited per IP via
# the same Redis counter used by /reviews — at most N investment audits per
# hour to avoid abusing the engine's MC capacity.
class Valuations::InvestmentController < ApplicationController
  RATE_LIMIT = { count: 5, window: 1.hour }.freeze

  # PropertyType.slug → PropertyValuation.property_type enum.
  # See db: PropertyType is `flat/room/house/land/commerce/garage`,
  # PropertyValuation accepts `apartment/room/house/land/commercial/garage`.
  REALTY_TO_PV_TYPE = {
    'flat' => 'apartment',
    'commerce' => 'commercial'
  }.freeze

  # Property.condition (integer enum) → PropertyValuation.property_condition (string).
  # Property: needs_repair / normal / renovated / euro / designer
  # Valuation: needs_repair / average / good / excellent / designer
  CONDITION_TO_PV = {
    'normal' => 'average',
    'renovated' => 'good',
    'euro' => 'excellent'
  }.freeze

  def new
    @valuation = PropertyValuation.new(
      audit_mode: 'investment',
      deal_type: 'sale',
      property_type: 'apartment'
    )
    prefill_from_property!(params[:from_property]) if params[:from_property].present?
    apply_calc_prefill!  # ?price=&mortgage_rate=&down_payment_pct= from /services/mortgage
    @macro = MacroRatesService.call
    @initial_rate_overrides = @valuation.evaluation_data&.dig('user_overrides') || {}
    # Static address suggestions kept as a fallback datalist for browsers
    # without JS / old caches. Dadata autocomplete (Phase 4.6 task #135)
    # supersedes this when present.
    @address_suggestions = Rails.cache.fetch('valuations:address_suggestions:v1', expires_in: 1.hour) do
      Property.on_site
              .where.not(address: [nil, ''])
              .order(updated_at: :desc)
              .limit(150)
              .pluck(:address)
              .uniq
    end
  end

  def create
    if rate_limited?
      flash[:alert] = 'Слишком много запросов. Попробуйте через час.'
      redirect_to new_investment_audit_path and return
    end

    @valuation = PropertyValuation.new(valuation_params.merge(
      audit_mode: 'investment',
      status: 'pending',
      ip_address: request.remote_ip,
      user_agent: request.user_agent
    ))

    # Telemetry: if this audit originated from a property page, remember
    # which one so analytics can attribute funnel → catalog → audit, and
    # snapshot the asking price at capture (Topnlab may shift it later).
    attach_property_source(@valuation, params[:from_property]) if params[:from_property].present?

    # User-supplied rate overrides — stored under `evaluation_data.user_overrides`
    # so AuditEngine::AuditRequest can pull them when building the engine
    # payload. nil/blank values fall back to engine defaults (macro_economics).
    attach_rate_overrides(@valuation, params[:rate_overrides])

    if @valuation.save
      InvestmentAuditJob.perform_later(@valuation.id)
      redirect_to investment_audit_show_path(token: @valuation.token)
    else
      render :new, status: :unprocessable_entity
    end
  end

  def show
    @valuation = PropertyValuation.find_by!(token: params[:token])
    @audit          = @valuation.evaluation_data&.dig('audit')
    @monte_carlo    = @valuation.evaluation_data&.dig('monte_carlo')
    @bank_offers    = @valuation.evaluation_data&.dig('bank_offers')
  end

  # JSON status endpoint for the loader's polling fallback. The WebSocket
  # path is preferred; this is the safety net when WS drops / page reload
  # during job execution.
  def status
    valuation = PropertyValuation.find_by!(token: params[:token])
    render json: {
      status: valuation.status,
      verdict: valuation.evaluation_data&.dig('audit', 'verdict'),
      error: valuation.evaluation_data&.dig('error', 'body')
    }
  end

  def download_pdf
    valuation = PropertyValuation.find_by!(token: params[:token])
    unless valuation.completed? && valuation.evaluation_data&.dig('audit').present?
      redirect_to investment_audit_show_path(token: valuation.token),
                  alert: 'Отчёт пока не готов.' and return
    end

    # PDF is built server-side from the stored evaluation_data via Prawn —
    # audit-engine has its own WeasyPrint generator but no HTTP endpoint
    # exposes it (см. services/audit-engine/SKILL_API_CONTRACT.md — нет /pdf).
    pdf_data = AuditPdfGenerator.call(valuation)
    send_data pdf_data,
              filename: "audit-#{valuation.token}.pdf",
              type: 'application/pdf',
              disposition: 'attachment'
  rescue StandardError => e
    Rails.logger.warn("[InvestmentController#download_pdf] #{e.class}: #{e.message}")
    redirect_to investment_audit_show_path(token: valuation.token),
                alert: 'PDF временно недоступен. Попробуйте обновить страницу.'
  end

  private

  # Loads a Property by slug (or numeric id) — uses friendly_id `.friendly.find`
  # so renamed slugs resolve via slug history. Deliberately NOT scoped to
  # in_advertising — a buyer clicking from a saved link to a now-archived
  # property should still be able to audit it.
  def prefill_from_property!(slug_or_id)
    prop = Property.friendly.find(slug_or_id)
    return unless prop

    @source_property = prop

    realty_slug = prop.property_type&.slug
    pv_type = REALTY_TO_PV_TYPE.fetch(realty_slug, realty_slug || 'apartment')

    # Land objects: area is in m² in Property; PropertyValuation expects
    # `land_area` in сотках. Convert. For non-land, total_area is m² directly.
    area_value = realty_slug == 'land' ? nil : prop.area
    land_value = if prop.land_area_m2.present? && prop.land_area_m2.positive?
                   (prop.land_area_m2.to_f / 100.0).round(2)
                 end

    @valuation.assign_attributes(
      property_type: pv_type,
      address: prop.address,
      city: 'Рязань', # Property has no city column — single-city catalog
      district: prop.district,
      total_area: area_value, land_area: land_value,
      rooms: prop.rooms, floor: prop.floor, total_floors: prop.total_floors,
      building_year: prop.building_year, building_type: prop.building_type,
      property_condition: CONDITION_TO_PV.fetch(prop.condition.to_s, prop.condition.to_s),
      estimated_price: prop.price,
      metro_station: prop.metro_station, metro_distance: prop.metro_distance
    )
  rescue ActiveRecord::RecordNotFound
    # Property was physically deleted — fall through with blank form.
    nil
  end

  # Calc-page → audit-form prefill (B.1 cross-link).
  # Accepts ?price=&mortgage_rate=&down_payment_pct= from /services/mortgage
  # so the «Запустить аудит» CTA on the calculator carries the user's chosen
  # rate/down-payment into the audit form. Validates ranges before applying.
  def apply_calc_prefill!
    price = params[:price].presence&.to_i
    @valuation.estimated_price ||= price if price && price.positive?

    rate = params[:mortgage_rate].presence&.to_f
    dpct = params[:down_payment_pct].presence&.to_f

    return unless (rate && rate.positive? && rate <= 50) || dpct

    @valuation.evaluation_data ||= {}
    overrides = @valuation.evaluation_data['user_overrides'] || {}
    overrides['mortgage_rate']    = rate if rate && rate.positive? && rate <= 50
    overrides['down_payment_pct'] = dpct if dpct && dpct >= 0 && dpct <= 100
    @valuation.evaluation_data['user_overrides'] = overrides
  end

  def attach_property_source(valuation, slug_or_id)
    prop = Property.friendly.find(slug_or_id)
    valuation.evaluation_data ||= {}
    valuation.evaluation_data['source_property_id']     = prop.id
    valuation.evaluation_data['source_property_slug']   = prop.slug
    valuation.evaluation_data['source_price_at_capture'] = valuation.estimated_price&.to_s
    valuation.evaluation_data['source_captured_at']      = Time.current.iso8601
  rescue ActiveRecord::RecordNotFound
    nil
  end

  # Sanitise + persist user-entered ставки overrides. Allowed keys:
  # mortgage_rate, deposit_rate, price_growth_annual — each must be in
  # [0, 50]. Additionally accepts deposit_program_id (the id from
  # Deposit::ProgramsService) — when set, the program's rate overrides
  # any manually-typed deposit_rate, and the program reference is stored
  # so the result page can show "сравнили с депозитом Альфа-Банка 17.0%".
  # Anything else is dropped silently (better than rejecting a whole
  # submission for a typo'd rate field).
  def attach_rate_overrides(valuation, overrides_param)
    return unless overrides_param.is_a?(ActionController::Parameters) || overrides_param.is_a?(Hash)
    raw = overrides_param.to_unsafe_h.with_indifferent_access

    cleaned = %w[mortgage_rate deposit_rate price_growth_annual].each_with_object({}) do |k, h|
      v = raw[k]&.to_s&.tr(',', '.')&.to_f
      h[k] = v.round(2) if v && v.positive? && v <= 50
    end

    if (program_id = raw['deposit_program_id'].presence)
      program = Deposit::ProgramsService.find_by_id(program_id)
      if program
        cleaned['deposit_rate']       = program[:rate_max].to_f.round(2)
        cleaned['deposit_program_id'] = program_id
        cleaned['deposit_program_label'] = "#{program[:bank_name]} · #{program[:product_name]}"
      end
    end

    return if cleaned.empty?
    valuation.evaluation_data ||= {}
    valuation.evaluation_data['user_overrides'] = cleaned
  end

  def valuation_params
    params.require(:property_valuation).permit(
      :property_type, :deal_type, :address, :city, :district,
      :total_area, :land_area, :rooms, :floor, :total_floors,
      :building_year, :property_condition,
      :estimated_price, # in Investment mode: asking price the buyer is considering
      :name, :email, :phone,
      :metro_station, :metro_distance,
      :has_balcony, :has_loggia, :has_garage
    )
  end

  def rate_limited?
    return false unless defined?(Redis)
    key = "investment_audit:submit:#{request.remote_ip}"
    redis = Redis.new(url: ENV.fetch('REDIS_URL', 'redis://redis:6379/1'))
    count = redis.incr(key)
    redis.expire(key, RATE_LIMIT[:window].to_i) if count == 1
    count > RATE_LIMIT[:count]
  rescue Redis::BaseError => e
    Rails.logger.warn("[InvestmentController] rate-limit Redis error: #{e.message}")
    false
  end
end
