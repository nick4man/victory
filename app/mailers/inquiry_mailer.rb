# frozen_string_literal: true

# Inquiry Mailer
# Sends emails related to inquiries and contact forms
class InquiryMailer < ApplicationMailer
  # Notify managers about new inquiry
  # @param inquiry [Inquiry]
  def new_inquiry_notification(inquiry)
    @inquiry = inquiry
    @property = inquiry.property
    @user = inquiry.user
    @admin_url = admin_inquiry_url(inquiry) rescue dashboard_inquiries_url
    
    attach_logo
    
    mail(
      to: ENV.fetch('ADMIN_EMAIL', 'admin@viktory-realty.ru'),
      cc: ENV.fetch('MANAGER_EMAILS', '').split(','),
      subject: "[Новая заявка] #{inquiry.inquiry_type.humanize} - #{inquiry.name}",
      template_name: 'new_inquiry_notification'
    )
  end
  
  # Send confirmation to user
  # @param inquiry [Inquiry]
  def inquiry_confirmation(inquiry)
    return unless inquiry.email.present?
    
    @inquiry = inquiry
    @property = inquiry.property
    @contact_phone = ENV.fetch('CONTACT_PHONE', '+7 (999) 123-45-67')
    @contact_email = ENV.fetch('CONTACT_EMAIL', 'info@viktory-realty.ru')
    
    attach_logo
    track_email("inquiry_#{inquiry.id}")
    
    mail(
      to: inquiry.email,
      subject: 'Мы получили вашу заявку',
      template_name: 'inquiry_confirmation'
    )
  end
  
  # Notify about callback request
  # @param inquiry [Inquiry]
  def callback_requested(inquiry)
    @inquiry = inquiry
    @admin_url = admin_inquiry_url(inquiry) rescue dashboard_inquiries_url
    @preferred_time = inquiry.metadata&.dig('preferred_time') || 'Как можно скорее'
    
    attach_logo
    
    # Send to managers with high priority
    mail(
      to: ENV.fetch('MANAGER_EMAILS', ENV.fetch('ADMIN_EMAIL', 'admin@viktory-realty.ru')).split(','),
      subject: "[СРОЧНО] Обратный звонок - #{inquiry.name} (#{format_phone(inquiry.phone)})",
      priority: 'high',
      template_name: 'callback_requested'
    )
  end
  
  # Send consultation request notification
  # @param inquiry [Inquiry]
  def consultation_requested(inquiry)
    @inquiry = inquiry
    @consultation_type = inquiry.metadata&.dig('consultation_type') || 'Общая консультация'
    @preferred_date = inquiry.metadata&.dig('preferred_date')
    @admin_url = admin_inquiry_url(inquiry) rescue dashboard_inquiries_url
    
    attach_logo
    
    mail(
      to: ENV.fetch('ADMIN_EMAIL', 'admin@viktory-realty.ru'),
      subject: "[Консультация] #{@consultation_type} - #{inquiry.name}",
      template_name: 'consultation_requested'
    )
  end
  
  # Send mortgage application notification
  # @param inquiry [Inquiry]
  def mortgage_application_received(inquiry)
    @inquiry = inquiry
    @property_price = inquiry.metadata&.dig('property_price')
    @down_payment = inquiry.metadata&.dig('down_payment')
    @loan_term = inquiry.metadata&.dig('loan_term')
    @monthly_income = inquiry.metadata&.dig('monthly_income')
    
    attach_logo
    
    # Send to mortgage department
    mail(
      to: ENV.fetch('MORTGAGE_EMAIL', ENV.fetch('ADMIN_EMAIL', 'admin@viktory-realty.ru')),
      subject: "[Ипотека] Заявка от #{inquiry.name}",
      template_name: 'mortgage_application_received'
    )
  end
  
  # Send property selection request with matching properties
  # @param inquiry [Inquiry]
  # @param properties [Array<Property>]
  def property_selection_request(inquiry, properties = [])
    return unless inquiry.email.present?
    
    @inquiry = inquiry
    @properties = properties
    @criteria = inquiry.metadata
    @search_url = properties_url(
      q: {
        property_type_eq: @criteria['property_type'],
        deal_type_eq: @criteria['deal_type'],
        price_gteq: @criteria['min_price'],
        price_lteq: @criteria['max_price']
      }
    )
    
    attach_logo
    track_email("selection_#{inquiry.id}")
    
    mail(
      to: inquiry.email,
      subject: "Подобрали #{properties.count} объектов по вашим критериям",
      template_name: 'property_selection_request'
    )
  end
  
  # Send inquiry status update
  # @param inquiry [Inquiry]
  def status_update(inquiry)
    return unless inquiry.email.present?
    
    @inquiry = inquiry
    @status_text = I18n.t("inquiry_status.#{inquiry.status}")
    @dashboard_url = dashboard_inquiry_url(inquiry) rescue dashboard_inquiries_url
    
    attach_logo
    
    mail(
      to: inquiry.email,
      subject: "Статус вашей заявки изменен: #{@status_text}",
      template_name: 'status_update'
    )
  end
  
  private
  
  def admin_inquiry_url(inquiry)
    "#{ENV.fetch('APP_URL', 'http://localhost:3000')}/admin/inquiries/#{inquiry.id}"
  end
  
  def dashboard_inquiries_url
    "#{ENV.fetch('APP_URL', 'http://localhost:3000')}/dashboard/inquiries"
  end
  
  def dashboard_inquiry_url(inquiry)
    "#{ENV.fetch('APP_URL', 'http://localhost:3000')}/dashboard/inquiries/#{inquiry.id}"
  end
  
  def properties_url(params = {})
    "#{ENV.fetch('APP_URL', 'http://localhost:3000')}/properties?#{params.to_query}"
  end
end

