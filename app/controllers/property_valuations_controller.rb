# frozen_string_literal: true

# Property Valuations Controller
# Handles property valuation requests and provides instant estimates
class PropertyValuationsController < ApplicationController
  # Cost cap для paid LLM chain (LLM_CHAIN_ANALYSIS=Sonnet 4.6+Haiku).
  # Каждая оценка стоит ~$0.25-0.40 (Tavily + Firecrawl + Sonnet parse +
  # AiCompFilter + AiExplainer). Без лимита бот мог бы drain account за
  # час. Mirror'им pattern из Valuations::InvestmentController:17,243-253.
  RATE_LIMIT = { count: 5, window: 1.hour }.freeze

  before_action :set_breadcrumbs
  before_action :enforce_rate_limit, only: :create

  # GET /sell/valuation/new
  def new
    @valuation = PropertyValuation.new
    @step = params[:step]&.to_i || 1
    
    set_meta_tags(
      title: 'Онлайн-оценка недвижимости - АН Виктори',
      description: 'Узнайте рыночную стоимость вашей недвижимости за 2 минуты. Бесплатная онлайн-оценка с использованием AI.',
      keywords: 'оценка недвижимости, оценка квартиры, узнать стоимость квартиры'
    )
    
    track_event('valuation_form_viewed', { step: @step })
  end
  
  # POST /sell/valuation
  #
  # Async-flow (mirrors Valuations::InvestmentController#create pattern):
  #   1. Save PropertyValuation with status: 'pending' immediately.
  #   2. Enqueue PropertyValuationJob (computes price, sends mailer, CRM,
  #      Telegram staff dispatch — all only when status flips to :completed).
  #   3. Redirect to /:token/result which renders processing.html.erb loader
  #      while pending, then result.html.erb when completed.
  #
  # Staff Telegram (ExpressReportNotifier) теперь срабатывает ВНУТРИ job'а
  # only после status: :completed — соответствует user requirement: «в
  # группу сотрудникам отправлять только после получения результата».
  def create
    @valuation = PropertyValuation.new(valuation_params)
    @valuation.user        = current_user if user_signed_in?
    @valuation.ip_address  = request.remote_ip
    @valuation.user_agent  = request.user_agent
    @valuation.status      = 'pending'

    if @valuation.save
      PropertyValuationJob.perform_later(@valuation.id)

      track_event('valuation_submitted', {
        property_type: @valuation.property_type,
        has_email:     @valuation.email.present?
      })

      redirect_to result_property_valuations_path(token: @valuation.token)
    else
      @step = determine_error_step
      flash.now[:alert] = 'Пожалуйста, исправьте ошибки в форме'
      render :new, status: :unprocessable_entity
    end
  end
  
  # GET /sell/valuation/:token/result
  def result
    @valuation = PropertyValuation.find_by!(token: params[:token])

    # Async loader: если PropertyValuationJob ещё работает, рендерим страницу
    # ожидания со spinner'ом + JS-polling on /:token/status. Соответствует
    # pattern'у investment audit (см. Valuations::InvestmentController#show).
    return render :processing, layout: 'application' if @valuation.pending?
    return render :failed,     layout: 'application' if @valuation.failed?

    # evaluation_data is jsonb — Rails returns a Hash directly. Legacy rows
    # that were stored as JSON strings get parsed once; new rows pass through.
    raw = @valuation.evaluation_data
    @evaluation_result = case raw
                         when Hash   then raw.deep_symbolize_keys
                         when String then (JSON.parse(raw, symbolize_names: true) rescue {})
                         else {}
                         end
    @similar_properties = find_similar_properties(@valuation)

    set_meta_tags(
      title: "Результат оценки недвижимости - #{helpers.number_to_currency(@valuation.estimated_price, precision: 0)}",
      description: "Оценочная стоимость вашей недвижимости составляет #{helpers.number_to_currency(@valuation.estimated_price, precision: 0)}"
    )

    track_event('valuation_result_viewed', {
      valuation_id: @valuation.id,
      estimated_price: @valuation.estimated_price
    })
  rescue ActiveRecord::RecordNotFound
    redirect_to new_property_valuation_path, alert: 'Оценка не найдена'
  end

  # GET /valuations/:token/status — JSON polling endpoint для loader'а на
  # processing.html.erb. Возвращает {status, age_seconds}. Status один из
  # 'pending' / 'completed' / 'failed' (PropertyValuation.statuses).
  def status
    valuation = PropertyValuation.find_by!(token: params[:token])
    render json: {
      status:      valuation.status,
      age_seconds: (Time.current - valuation.created_at).to_i
    }
  rescue ActiveRecord::RecordNotFound
    render json: { status: 'not_found' }, status: :not_found
  end
  
  # GET /sell/valuation/:token/download — Express valuation PDF report.
  # Uses PdfGeneratorService (Prawn + DejaVuSans for Cyrillic). The report
  # includes a QR code for the Telegram channel + site URL on the footer.
  def download_pdf
    @valuation = PropertyValuation.find_by!(token: params[:token])
    pdf_bytes = PdfGeneratorService.new(@valuation).call
    send_data pdf_bytes,
              filename: "valuation-#{@valuation.report_label.tr('№', '')}.pdf",
              type: 'application/pdf',
              disposition: 'attachment'

    track_event('valuation_pdf_downloaded', { valuation_id: @valuation.id }) rescue nil
  rescue ActiveRecord::RecordNotFound
    redirect_to new_property_valuation_path, alert: 'Оценка не найдена'
  rescue StandardError => e
    Rails.logger.warn("[PropertyValuations#download_pdf] #{e.class}: #{e.message}")
    redirect_to result_property_valuations_path(token: params[:token]),
                alert: 'PDF временно недоступен. Попробуйте обновить страницу.'
  end
  
  # POST /sell/valuation/:token/request_call
  def request_call
    @valuation = PropertyValuation.find_by!(token: params[:token])
    
    if @valuation.update(call_requested: true, call_requested_at: Time.current)
      # Create inquiry for callback
      inquiry = Inquiry.create!(
        user: current_user,
        inquiry_type: 'callback',
        status: 'new',
        name: @valuation.name,
        email: @valuation.email,
        phone: @valuation.phone,
        message: "Запрос обратного звонка по оценке недвижимости (#{@valuation.address})",
        source: 'valuation',
        metadata: { valuation_id: @valuation.id }
      )
      
      # Notify managers
      InquiryMailer.new_inquiry_notification(inquiry).deliver_later
      
      track_event('valuation_callback_requested', { valuation_id: @valuation.id })
      
      respond_to do |format|
        format.html { redirect_to result_property_valuations_path(token: @valuation.token), notice: 'Заявка на звонок принята! Мы свяжемся с вами в ближайшее время.' }
        format.json { render json: { success: true, message: 'Заявка принята' } }
      end
    else
      respond_to do |format|
        format.html { redirect_to result_property_valuations_path(token: @valuation.token), alert: 'Ошибка при отправке заявки' }
        format.json { render json: { success: false, error: 'Ошибка' }, status: :unprocessable_entity }
      end
    end
  rescue ActiveRecord::RecordNotFound
    redirect_to new_property_valuation_path, alert: 'Оценка не найдена'
  end
  
  private
  
  def valuation_params
    permitted = params.require(:property_valuation).permit(
      :property_type, :deal_type, :address, :city, :district,
      :total_area, :living_area, :kitchen_area, :rooms, :floor, :total_floors,
      :land_area, :land_category, :ownership_type,
      :building_type, :building_year, :property_condition, :condition,
      :has_balcony, :has_loggia, :has_garage,
      :metro_station, :metro_distance, :description,
      :name, :email, :phone,
      photos: []
    )

    # Tolerate legacy form submissions that send `condition` instead of `property_condition`.
    legacy = permitted.delete(:condition)
    permitted[:property_condition] ||= legacy if legacy.present?
    permitted[:property_condition] = nil if permitted[:property_condition].blank?
    permitted
  end
  
  def set_breadcrumbs
    add_breadcrumb 'Главная', root_path
    add_breadcrumb 'Продать недвижимость', sell_root_path
    
    case action_name
    when 'new', 'create'
      add_breadcrumb 'Онлайн-оценка', new_property_valuation_path
    when 'result'
      add_breadcrumb 'Результат оценки'
    end
  end
  
  def determine_error_step
    return 1 if @valuation.errors.any? { |error| %i[property_type deal_type address].include?(error.attribute) }
    return 2 if @valuation.errors.any? { |error| %i[total_area land_area rooms floor total_floors land_category ownership_type].include?(error.attribute) }
    return 3 if @valuation.errors.any? { |error| %i[building_type building_year property_condition].include?(error.attribute) }
    return 4 if @valuation.errors.any? { |error| %i[name phone email].include?(error.attribute) }

    1
  end
  
  def find_similar_properties(valuation)
    return Property.none if valuation.estimated_price.blank? || valuation.estimated_price.zero?

    pt_id = PropertyType.find_by(slug: comparable_property_type_slug(valuation.property_type))&.id
    return Property.none unless pt_id

    Property.published
            .where('price > 0 AND area > 0')
            .where(property_type_id: pt_id, deal_type: valuation.deal_type)
            .where('area BETWEEN ? AND ?', valuation.total_area.to_f * 0.8, valuation.total_area.to_f * 1.2)
            .where('price BETWEEN ? AND ?', valuation.min_price.to_i, valuation.max_price.to_i)
            .limit(6)
  end

  def comparable_property_type_slug(pt)
    { 'apartment' => 'flat', 'house' => 'house', 'land' => 'land',
      'commercial' => 'commerce', 'garage' => 'garage', 'room' => 'room' }[pt.to_s]
  end
  
  def create_crm_lead(valuation)
    # Integration with CRM (AmoCRM, Bitrix24, etc.)
    # This would be implemented based on your CRM system
    
    Rails.logger.info "Creating CRM lead for valuation ##{valuation.id}"
    
    # Example structure:
    # AmoCrmService.create_lead(
    #   name: "Оценка: #{valuation.address}",
    #   email: valuation.email,
    #   phone: valuation.phone,
    #   custom_fields: {
    #     property_type: valuation.property_type,
    #     estimated_price: valuation.estimated_price
    #   }
    # )
  rescue StandardError => e
    Rails.logger.error "Failed to create CRM lead: #{e.message}"
  end

  # Cost cap: 5 valuations per hour per IP. Soft-fail если Redis недоступен
  # (rescue ниже возвращает false → no rate-limit). Используем DB 1 как
  # investment_controller, отдельный namespace `valuation_express:submit:*`.
  def enforce_rate_limit
    return unless rate_limited?

    flash[:alert] = 'Слишком много запросов на оценку с этого устройства. ' \
                    'Попробуйте через час или напишите нам напрямую.'
    redirect_to new_property_valuation_path
  end

  def rate_limited?
    return false unless defined?(Redis)

    key = "valuation_express:submit:#{request.remote_ip}"
    redis = Redis.new(url: ENV.fetch('REDIS_URL', 'redis://redis:6379/1'))
    count = redis.incr(key)
    redis.expire(key, RATE_LIMIT[:window].to_i) if count == 1
    count > RATE_LIMIT[:count]
  rescue Redis::BaseError => e
    Rails.logger.warn("[PropertyValuationsController] rate-limit Redis error: #{e.message}")
    false
  end
end

