# frozen_string_literal: true

# Property Valuations Controller
# Handles property valuation requests and provides instant estimates
class PropertyValuationsController < ApplicationController
  before_action :set_breadcrumbs
  
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
  def create
    @valuation = PropertyValuation.new(valuation_params)
    @valuation.user = current_user if user_signed_in?
    @valuation.ip_address = request.remote_ip
    @valuation.user_agent = request.user_agent
    
    if @valuation.save
      # Perform valuation using AI service
      result = PropertyEvaluationService.new(@valuation.to_property_params).call
      
      @valuation.update(
        estimated_price: result[:estimated_price],
        min_price: result[:price_range][:min],
        max_price: result[:price_range][:max],
        confidence_level: result[:confidence_level],
        evaluation_data: result.to_json,
        status: 'completed'
      )
      
      # Send email with results if email provided
      PropertyValuationMailer.valuation_completed(@valuation).deliver_later if @valuation.email.present?
      
      # Create lead in CRM
      create_crm_lead(@valuation) if @valuation.email.present?
      
      track_event('valuation_completed', {
        property_type: @valuation.property_type,
        estimated_price: @valuation.estimated_price
      })
      
      redirect_to property_valuation_result_path(@valuation.token), 
                  notice: 'Оценка успешно выполнена!'
    else
      @step = determine_error_step
      flash.now[:alert] = 'Пожалуйста, исправьте ошибки в форме'
      render :new, status: :unprocessable_entity
    end
  end
  
  # GET /sell/valuation/:token/result
  def result
    @valuation = PropertyValuation.find_by!(token: params[:token])
    @evaluation_result = JSON.parse(@valuation.evaluation_data, symbolize_names: true)
    @similar_properties = find_similar_properties(@valuation)
    
    set_meta_tags(
      title: "Результат оценки недвижимости - #{number_to_currency(@valuation.estimated_price, precision: 0)}",
      description: "Оценочная стоимость вашей недвижимости составляет #{number_to_currency(@valuation.estimated_price, precision: 0)}"
    )
    
    track_event('valuation_result_viewed', {
      valuation_id: @valuation.id,
      estimated_price: @valuation.estimated_price
    })
  rescue ActiveRecord::RecordNotFound
    redirect_to new_property_valuation_path, alert: 'Оценка не найдена'
  end
  
  # GET /sell/valuation/:token/download
  def download_pdf
    @valuation = PropertyValuation.find_by!(token: params[:token])
    @evaluation_result = JSON.parse(@valuation.evaluation_data, symbolize_names: true)
    
    respond_to do |format|
      format.pdf do
        pdf = PropertyValuationPdf.new(@valuation, @evaluation_result)
        send_data pdf.render,
                  filename: "valuation_#{@valuation.token}.pdf",
                  type: 'application/pdf',
                  disposition: 'attachment'
      end
    end
    
    track_event('valuation_pdf_downloaded', { valuation_id: @valuation.id })
  rescue ActiveRecord::RecordNotFound
    redirect_to new_property_valuation_path, alert: 'Оценка не найдена'
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
        format.html { redirect_to property_valuation_result_path(@valuation.token), notice: 'Заявка на звонок принята! Мы свяжемся с вами в ближайшее время.' }
        format.json { render json: { success: true, message: 'Заявка принята' } }
      end
    else
      respond_to do |format|
        format.html { redirect_to property_valuation_result_path(@valuation.token), alert: 'Ошибка при отправке заявки' }
        format.json { render json: { success: false, error: 'Ошибка' }, status: :unprocessable_entity }
      end
    end
  rescue ActiveRecord::RecordNotFound
    redirect_to new_property_valuation_path, alert: 'Оценка не найдена'
  end
  
  private
  
  def valuation_params
    params.require(:property_valuation).permit(
      :property_type, :deal_type, :address, :city, :district,
      :total_area, :living_area, :kitchen_area, :rooms, :floor, :total_floors,
      :building_type, :building_year, :condition, :has_balcony, :has_loggia,
      :has_garage, :metro_station, :metro_distance, :description,
      :name, :email, :phone,
      photos: []
    )
  end
  
  def set_breadcrumbs
    add_breadcrumb 'Главная', root_path
    add_breadcrumb 'Продать недвижимость', sell_path
    
    case action_name
    when 'new', 'create'
      add_breadcrumb 'Онлайн-оценка', new_property_valuation_path
    when 'result'
      add_breadcrumb 'Результат оценки'
    end
  end
  
  def determine_error_step
    return 1 if @valuation.errors.any? { |error| [:property_type, :deal_type, :address].include?(error.attribute) }
    return 2 if @valuation.errors.any? { |error| [:total_area, :rooms, :floor].include?(error.attribute) }
    return 3 if @valuation.errors.any? { |error| [:building_type, :condition].include?(error.attribute) }
    return 4 if @valuation.errors.any? { |error| [:name, :phone, :email].include?(error.attribute) }
    
    1
  end
  
  def find_similar_properties(valuation)
    Property.active
            .where(property_type: valuation.property_type)
            .where('total_area BETWEEN ? AND ?', valuation.total_area * 0.8, valuation.total_area * 1.2)
            .where('price BETWEEN ? AND ?', valuation.min_price, valuation.max_price)
            .limit(6)
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
end

