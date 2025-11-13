# frozen_string_literal: true

# Contact Forms Controller
# Handles various contact forms (quick inquiry, viewing schedule, callback, etc.)
class ContactFormsController < ApplicationController
  skip_before_action :verify_authenticity_token, only: [:create], if: -> { request.format.json? }
  before_action :set_property, only: [:viewing_schedule, :property_inquiry]
  
  # POST /contact_forms/quick_inquiry
  def quick_inquiry
    @inquiry = Inquiry.new(quick_inquiry_params)
    @inquiry.inquiry_type = 'quick_inquiry'
    @inquiry.user = current_user if user_signed_in?
    @inquiry.status = 'new'
    @inquiry.source = 'website'
    @inquiry.ip_address = request.remote_ip
    @inquiry.user_agent = request.user_agent
    
    if @inquiry.save
      # Send notifications
      InquiryMailer.new_inquiry_notification(@inquiry).deliver_later
      InquiryMailer.inquiry_confirmation(@inquiry).deliver_later if @inquiry.email.present?
      
      # Send to CRM
      create_crm_lead(@inquiry)
      
      # Track event
      track_event('quick_inquiry_submitted', {
        inquiry_id: @inquiry.id,
        property_id: @inquiry.property_id
      })
      
      respond_to do |format|
        format.html { redirect_back fallback_location: root_path, notice: 'Спасибо! Ваша заявка принята. Мы свяжемся с вами в ближайшее время.' }
        format.json { render json: { success: true, message: 'Заявка принята', inquiry_id: @inquiry.id }, status: :created }
      end
    else
      respond_to do |format|
        format.html { redirect_back fallback_location: root_path, alert: "Ошибка: #{@inquiry.errors.full_messages.join(', ')}" }
        format.json { render json: { success: false, errors: @inquiry.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end
  
  # POST /contact_forms/viewing_schedule
  def viewing_schedule
    @viewing = ViewingSchedule.new(viewing_params)
    @viewing.user = current_user if user_signed_in?
    @viewing.property = @property
    @viewing.status = 'pending'
    
    if @viewing.save
      # Create inquiry
      create_viewing_inquiry(@viewing)
      
      # Send notifications
      ViewingMailer.viewing_requested(@viewing).deliver_later
      ViewingMailer.viewing_confirmation(@viewing).deliver_later if @viewing.email.present?
      
      track_event('viewing_scheduled', {
        viewing_id: @viewing.id,
        property_id: @property.id,
        preferred_date: @viewing.preferred_date
      })
      
      respond_to do |format|
        format.html { redirect_to property_path(@property), notice: 'Запись на показ принята! Мы свяжемся с вами для подтверждения.' }
        format.json { render json: { success: true, message: 'Запись принята', viewing_id: @viewing.id }, status: :created }
      end
    else
      respond_to do |format|
        format.html { redirect_to property_path(@property), alert: "Ошибка: #{@viewing.errors.full_messages.join(', ')}" }
        format.json { render json: { success: false, errors: @viewing.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end
  
  # POST /contact_forms/callback
  def callback
    @inquiry = Inquiry.new(callback_params)
    @inquiry.inquiry_type = 'callback'
    @inquiry.user = current_user if user_signed_in?
    @inquiry.status = 'new'
    @inquiry.source = 'website'
    @inquiry.priority = determine_priority(@inquiry)
    
    if @inquiry.save
      # Send notifications
      InquiryMailer.callback_requested(@inquiry).deliver_later
      
      # Send SMS to managers if urgent
      send_urgent_sms(@inquiry) if @inquiry.priority == 'urgent'
      
      # Create CRM task
      create_crm_task(@inquiry, 'callback')
      
      track_event('callback_requested', {
        inquiry_id: @inquiry.id,
        phone: @inquiry.phone,
        preferred_time: @inquiry.metadata&.dig('preferred_time')
      })
      
      respond_to do |format|
        format.html { redirect_back fallback_location: root_path, notice: 'Заявка на звонок принята! Мы перезвоним вам в течение 15 минут.' }
        format.json { render json: { success: true, message: 'Заявка принята' }, status: :created }
      end
    else
      respond_to do |format|
        format.html { redirect_back fallback_location: root_path, alert: "Ошибка: #{@inquiry.errors.full_messages.join(', ')}" }
        format.json { render json: { success: false, errors: @inquiry.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end
  
  # POST /contact_forms/consultation
  def consultation
    @inquiry = Inquiry.new(consultation_params)
    @inquiry.inquiry_type = 'consultation'
    @inquiry.user = current_user if user_signed_in?
    @inquiry.status = 'new'
    @inquiry.source = 'website'
    
    if @inquiry.save
      # Send notifications
      InquiryMailer.consultation_requested(@inquiry).deliver_later
      
      # Create calendar event for agent
      create_calendar_event(@inquiry) if @inquiry.metadata&.dig('preferred_date').present?
      
      track_event('consultation_requested', {
        inquiry_id: @inquiry.id,
        consultation_type: @inquiry.metadata&.dig('consultation_type')
      })
      
      respond_to do |format|
        format.html { redirect_back fallback_location: root_path, notice: 'Заявка на консультацию принята! Мы свяжемся с вами для согласования времени.' }
        format.json { render json: { success: true, message: 'Заявка принята' }, status: :created }
      end
    else
      respond_to do |format|
        format.html { redirect_back fallback_location: root_path, alert: "Ошибка: #{@inquiry.errors.full_messages.join(', ')}" }
        format.json { render json: { success: false, errors: @inquiry.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end
  
  # POST /contact_forms/mortgage_application
  def mortgage_application
    @inquiry = Inquiry.new(mortgage_params)
    @inquiry.inquiry_type = 'mortgage'
    @inquiry.user = current_user if user_signed_in?
    @inquiry.status = 'new'
    @inquiry.source = 'website'
    
    if @inquiry.save
      # Send to mortgage partners
      send_to_mortgage_partners(@inquiry)
      
      # Send notifications
      InquiryMailer.mortgage_application_received(@inquiry).deliver_later
      
      track_event('mortgage_application_submitted', {
        inquiry_id: @inquiry.id,
        property_price: @inquiry.metadata&.dig('property_price'),
        down_payment: @inquiry.metadata&.dig('down_payment')
      })
      
      respond_to do |format|
        format.html { redirect_back fallback_location: root_path, notice: 'Заявка на ипотеку принята! Мы подберем для вас лучшие предложения.' }
        format.json { render json: { success: true, message: 'Заявка принята' }, status: :created }
      end
    else
      respond_to do |format|
        format.html { redirect_back fallback_location: root_path, alert: "Ошибка: #{@inquiry.errors.full_messages.join(', ')}" }
        format.json { render json: { success: false, errors: @inquiry.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end
  
  # POST /contact_forms/property_selection
  def property_selection
    @inquiry = Inquiry.new(selection_params)
    @inquiry.inquiry_type = 'property_selection'
    @inquiry.user = current_user if user_signed_in?
    @inquiry.status = 'new'
    @inquiry.source = 'website'
    
    if @inquiry.save
      # AI-powered property matching
      matching_properties = find_matching_properties(@inquiry)
      @inquiry.update(metadata: @inquiry.metadata.merge(matching_count: matching_properties.count))
      
      # Send notifications with matches
      InquiryMailer.property_selection_request(@inquiry, matching_properties).deliver_later
      
      track_event('property_selection_requested', {
        inquiry_id: @inquiry.id,
        criteria: @inquiry.metadata
      })
      
      respond_to do |format|
        format.html { redirect_back fallback_location: root_path, notice: 'Заявка принята! Мы подберем для вас подходящие варианты и пришлем на email.' }
        format.json { render json: { success: true, message: 'Заявка принята', matching_count: matching_properties.count }, status: :created }
      end
    else
      respond_to do |format|
        format.html { redirect_back fallback_location: root_path, alert: "Ошибка: #{@inquiry.errors.full_messages.join(', ')}" }
        format.json { render json: { success: false, errors: @inquiry.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end
  
  private
  
  def quick_inquiry_params
    params.require(:inquiry).permit(:name, :phone, :email, :message, :property_id)
  end
  
  def viewing_params
    params.require(:viewing_schedule).permit(
      :name, :phone, :email, :preferred_date, :preferred_time, :message
    )
  end
  
  def callback_params
    params.require(:inquiry).permit(:name, :phone, :preferred_time, :message).tap do |p|
      p[:metadata] = { preferred_time: params.dig(:inquiry, :preferred_time) }
    end
  end
  
  def consultation_params
    params.require(:inquiry).permit(:name, :phone, :email, :message, :consultation_type, :preferred_date).tap do |p|
      p[:metadata] = {
        consultation_type: params.dig(:inquiry, :consultation_type),
        preferred_date: params.dig(:inquiry, :preferred_date)
      }
    end
  end
  
  def mortgage_params
    params.require(:inquiry).permit(
      :name, :phone, :email, :property_id,
      :property_price, :down_payment, :loan_term, :monthly_income
    ).tap do |p|
      p[:metadata] = {
        property_price: params.dig(:inquiry, :property_price),
        down_payment: params.dig(:inquiry, :down_payment),
        loan_term: params.dig(:inquiry, :loan_term),
        monthly_income: params.dig(:inquiry, :monthly_income)
      }
    end
  end
  
  def selection_params
    params.require(:inquiry).permit(
      :name, :phone, :email, :message,
      :property_type, :deal_type, :min_price, :max_price, :rooms, :district
    ).tap do |p|
      p[:metadata] = {
        property_type: params.dig(:inquiry, :property_type),
        deal_type: params.dig(:inquiry, :deal_type),
        min_price: params.dig(:inquiry, :min_price),
        max_price: params.dig(:inquiry, :max_price),
        rooms: params.dig(:inquiry, :rooms),
        district: params.dig(:inquiry, :district)
      }
    end
  end
  
  def set_property
    @property = Property.friendly.find(params[:property_id]) if params[:property_id].present?
  rescue ActiveRecord::RecordNotFound
    redirect_to root_path, alert: 'Объект не найден'
  end
  
  def determine_priority(inquiry)
    # Urgent if callback requested in next 2 hours or during business hours
    now = Time.current
    business_hours = (9..18).cover?(now.hour) && now.wday.between?(1, 5)
    business_hours ? 'urgent' : 'normal'
  end
  
  def create_viewing_inquiry(viewing)
    Inquiry.create!(
      user: viewing.user,
      property: viewing.property,
      inquiry_type: 'viewing',
      status: 'new',
      name: viewing.name,
      phone: viewing.phone,
      email: viewing.email,
      message: "Запись на показ: #{viewing.preferred_date} в #{viewing.preferred_time}",
      source: 'website',
      metadata: {
        viewing_id: viewing.id,
        preferred_date: viewing.preferred_date,
        preferred_time: viewing.preferred_time
      }
    )
  end
  
  def find_matching_properties(inquiry)
    criteria = inquiry.metadata
    
    Property.active
            .where(property_type: criteria['property_type'])
            .where(deal_type: criteria['deal_type'])
            .where('price >= ? AND price <= ?', criteria['min_price'], criteria['max_price'])
            .where(rooms: criteria['rooms']) if criteria['rooms'].present?
            .limit(10)
  end
  
  def create_crm_lead(inquiry)
    # Integration with CRM
    Rails.logger.info "Creating CRM lead for inquiry ##{inquiry.id}"
    # AmoCrmService.create_lead(inquiry) if defined?(AmoCrmService)
  rescue StandardError => e
    Rails.logger.error "Failed to create CRM lead: #{e.message}"
  end
  
  def create_crm_task(inquiry, task_type)
    Rails.logger.info "Creating CRM task '#{task_type}' for inquiry ##{inquiry.id}"
  rescue StandardError => e
    Rails.logger.error "Failed to create CRM task: #{e.message}"
  end
  
  def send_urgent_sms(inquiry)
    # SMS notification for urgent callbacks
    Rails.logger.info "Sending urgent SMS for inquiry ##{inquiry.id}"
    # SmscService.send_sms(inquiry.phone, "Urgent callback request") if defined?(SmscService)
  rescue StandardError => e
    Rails.logger.error "Failed to send SMS: #{e.message}"
  end
  
  def create_calendar_event(inquiry)
    Rails.logger.info "Creating calendar event for inquiry ##{inquiry.id}"
  rescue StandardError => e
    Rails.logger.error "Failed to create calendar event: #{e.message}"
  end
  
  def send_to_mortgage_partners(inquiry)
    Rails.logger.info "Sending mortgage application to partners for inquiry ##{inquiry.id}"
  rescue StandardError => e
    Rails.logger.error "Failed to send to mortgage partners: #{e.message}"
  end
end

