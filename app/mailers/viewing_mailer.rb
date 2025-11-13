# frozen_string_literal: true

# Viewing Mailer
# Sends emails related to property viewing schedules
class ViewingMailer < ApplicationMailer
  # Notify managers about viewing request
  # @param viewing [ViewingSchedule]
  def viewing_requested(viewing)
    @viewing = viewing
    @property = viewing.property
    @date_time = format_datetime(viewing.preferred_date, viewing.preferred_time)
    @admin_url = admin_viewing_url(viewing) rescue property_url(viewing.property)
    
    attach_logo
    
    mail(
      to: ENV.fetch('MANAGER_EMAILS', ENV.fetch('ADMIN_EMAIL', 'admin@viktory-realty.ru')).split(','),
      subject: "[Показ] #{@property.title} - #{viewing.name}",
      template_name: 'viewing_requested'
    )
  end
  
  # Send confirmation to user
  # @param viewing [ViewingSchedule]
  def viewing_confirmation(viewing)
    return unless viewing.email.present?
    
    @viewing = viewing
    @property = viewing.property
    @date_time = format_datetime(viewing.preferred_date, viewing.preferred_time)
    @property_url = property_url(viewing.property)
    @contact_phone = ENV.fetch('CONTACT_PHONE', '+7 (999) 123-45-67')
    
    attach_logo
    track_email("viewing_#{viewing.id}")
    
    mail(
      to: viewing.email,
      subject: 'Запись на показ принята',
      template_name: 'viewing_confirmation'
    )
  end
  
  # Send viewing confirmation (after manager approval)
  # @param viewing [ViewingSchedule]
  def viewing_confirmed(viewing)
    return unless viewing.email.present?
    
    @viewing = viewing
    @property = viewing.property
    @agent = viewing.agent
    @date_time = format_datetime(viewing.preferred_date, viewing.preferred_time)
    @property_url = property_url(viewing.property)
    
    # Add to calendar attachment
    add_calendar_attachment(viewing)
    
    attach_logo
    
    mail(
      to: viewing.email,
      subject: 'Показ подтвержден - ждем вас!',
      template_name: 'viewing_confirmed'
    )
  end
  
  # Send viewing cancellation
  # @param viewing [ViewingSchedule]
  def viewing_cancelled(viewing)
    return unless viewing.email.present?
    
    @viewing = viewing
    @property = viewing.property
    @cancellation_reason = viewing.cancellation_reason || 'Не указана'
    @contact_phone = ENV.fetch('CONTACT_PHONE', '+7 (999) 123-45-67')
    @property_url = property_url(viewing.property)
    
    attach_logo
    
    mail(
      to: viewing.email,
      subject: 'Показ отменен',
      template_name: 'viewing_cancelled'
    )
  end
  
  # Send reminder before viewing
  # @param viewing [ViewingSchedule]
  def viewing_reminder(viewing)
    return unless viewing.email.present?
    
    @viewing = viewing
    @property = viewing.property
    @agent = viewing.agent
    @date_time = format_datetime(viewing.preferred_date, viewing.preferred_time)
    @property_url = property_url(viewing.property)
    @contact_phone = viewing.agent&.phone || ENV.fetch('CONTACT_PHONE', '+7 (999) 123-45-67')
    
    attach_logo
    
    mail(
      to: viewing.email,
      subject: 'Напоминание: показ завтра в ' + viewing.preferred_time,
      template_name: 'viewing_reminder'
    )
  end
  
  # Send thank you after viewing
  # @param viewing [ViewingSchedule]
  def viewing_completed(viewing)
    return unless viewing.email.present?
    
    @viewing = viewing
    @property = viewing.property
    @feedback_url = new_review_url(property_id: viewing.property_id)
    @similar_properties = find_similar_properties(viewing.property)
    
    attach_logo
    
    mail(
      to: viewing.email,
      subject: 'Спасибо за визит! Что вы думаете об объекте?',
      template_name: 'viewing_completed'
    )
  end
  
  # Notify agent about viewing assignment
  # @param viewing [ViewingSchedule]
  def agent_assignment(viewing)
    return unless viewing.agent&.email.present?
    
    @viewing = viewing
    @property = viewing.property
    @client = viewing.user
    @date_time = format_datetime(viewing.preferred_date, viewing.preferred_time)
    @admin_url = admin_viewing_url(viewing)
    
    attach_logo
    
    mail(
      to: viewing.agent.email,
      subject: "[Показ назначен] #{@property.title} - #{@date_time}",
      template_name: 'agent_assignment'
    )
  end
  
  private
  
  def format_datetime(date, time)
    return '' unless date && time
    
    "#{I18n.l(date, format: :long)} в #{time}"
  end
  
  def add_calendar_attachment(viewing)
    cal = <<~ICAL
      BEGIN:VCALENDAR
      VERSION:2.0
      PRODID:-//АН Виктори//Viewing Schedule//RU
      BEGIN:VEVENT
      UID:viewing-#{viewing.id}@viktory-realty.ru
      DTSTAMP:#{Time.current.utc.strftime('%Y%m%dT%H%M%SZ')}
      DTSTART:#{viewing.datetime.utc.strftime('%Y%m%dT%H%M%SZ')}
      DTEND:#{(viewing.datetime + viewing.duration_minutes.minutes).utc.strftime('%Y%m%dT%H%M%SZ')}
      SUMMARY:Показ недвижимости - #{viewing.property.title}
      DESCRIPTION:Показ объекта по адресу: #{viewing.property.address}
      LOCATION:#{viewing.property.address}
      STATUS:CONFIRMED
      END:VEVENT
      END:VCALENDAR
    ICAL
    
    attachments['viewing.ics'] = {
      mime_type: 'text/calendar',
      content: cal
    }
  rescue StandardError => e
    Rails.logger.error "Failed to create calendar attachment: #{e.message}"
  end
  
  def find_similar_properties(property)
    Property.active
            .where(property_type: property.property_type)
            .where.not(id: property.id)
            .limit(3)
  end
  
  def admin_viewing_url(viewing)
    "#{ENV.fetch('APP_URL', 'http://localhost:3000')}/admin/viewing_schedules/#{viewing.id}"
  end
  
  def property_url(property)
    "#{ENV.fetch('APP_URL', 'http://localhost:3000')}/properties/#{property.slug}"
  end
  
  def new_review_url(params = {})
    "#{ENV.fetch('APP_URL', 'http://localhost:3000')}/reviews/new?#{params.to_query}"
  end
end

