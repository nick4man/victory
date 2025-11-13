# frozen_string_literal: true

# Property Valuation Mailer
# Sends emails related to property valuations
class PropertyValuationMailer < ApplicationMailer
  # Send valuation results to user
  # @param valuation [PropertyValuation]
  def valuation_completed(valuation)
    @valuation = valuation
    @evaluation_result = JSON.parse(valuation.evaluation_data, symbolize_names: true)
    @result_url = property_valuation_result_url(valuation.token)
    @pdf_url = property_valuation_download_pdf_url(valuation.token, format: :pdf)
    
    attach_logo
    track_email("valuation_#{valuation.id}")
    
    mail(
      to: valuation.email,
      subject: "Результат оценки недвижимости - #{number_to_currency(valuation.estimated_price, precision: 0)}",
      template_name: 'valuation_completed'
    )
  end
  
  # Notify managers about new valuation
  # @param valuation [PropertyValuation]
  def new_valuation_notification(valuation)
    @valuation = valuation
    @admin_url = admin_property_valuation_url(valuation) rescue property_valuation_result_url(valuation.token)
    
    attach_logo
    
    mail(
      to: ENV.fetch('ADMIN_EMAIL', 'admin@viktory-realty.ru'),
      cc: ENV.fetch('MANAGER_EMAILS', '').split(','),
      subject: "[Новая оценка] #{valuation.property_type} - #{valuation.address}",
      template_name: 'new_valuation_notification'
    )
  end
  
  # Send reminder to complete valuation
  # @param valuation [PropertyValuation]
  def completion_reminder(valuation)
    return unless valuation.email.present?
    
    @valuation = valuation
    @continue_url = new_property_valuation_url(step: 4)
    
    attach_logo
    
    mail(
      to: valuation.email,
      subject: 'Завершите оценку недвижимости',
      template_name: 'completion_reminder'
    )
  end
  
  # Send callback confirmation
  # @param valuation [PropertyValuation]
  def callback_confirmation(valuation)
    return unless valuation.email.present?
    
    @valuation = valuation
    @contact_phone = ENV.fetch('CONTACT_PHONE', '+7 (999) 123-45-67')
    
    attach_logo
    
    mail(
      to: valuation.email,
      subject: 'Мы получили вашу заявку на звонок',
      template_name: 'callback_confirmation'
    )
  end
  
  # Send follow-up email after valuation
  # @param valuation [PropertyValuation]
  def follow_up(valuation)
    return unless valuation.email.present?
    
    @valuation = valuation
    @result_url = property_valuation_result_url(valuation.token)
    @contact_url = contacts_url
    
    attach_logo
    
    mail(
      to: valuation.email,
      subject: 'Как продвигается продажа вашей недвижимости?',
      template_name: 'follow_up'
    )
  end
  
  private
  
  def number_to_currency(amount, options = {})
    ActionController::Base.helpers.number_to_currency(amount, options.merge(unit: '₽', separator: ',', delimiter: ' '))
  end
  
  def property_valuation_result_url(token)
    "#{ENV.fetch('APP_URL', 'http://localhost:3000')}/valuations/#{token}/result"
  end
  
  def property_valuation_download_pdf_url(token, options = {})
    "#{ENV.fetch('APP_URL', 'http://localhost:3000')}/valuations/#{token}/download"
  end
  
  def new_property_valuation_url(params = {})
    "#{ENV.fetch('APP_URL', 'http://localhost:3000')}/valuations/new?#{params.to_query}"
  end
  
  def admin_property_valuation_url(valuation)
    "#{ENV.fetch('APP_URL', 'http://localhost:3000')}/admin/property_valuations/#{valuation.id}"
  end
  
  def contacts_url
    "#{ENV.fetch('APP_URL', 'http://localhost:3000')}/contacts"
  end
end

