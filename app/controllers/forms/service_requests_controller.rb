# frozen_string_literal: true

module Forms
  # Receives service inquiries from the public /services modal.
  # Creates a local Inquiry; agent later transfers it to Topnlab CRM
  # (because the Topnlab call-center API is intentionally not wired up yet).
  class ServiceRequestsController < ApplicationController
    skip_before_action :verify_authenticity_token, only: [:create], raise: false

    def create
      service = ServiceType.find_by(slug: params[:service_slug])
      attrs = {
        inquiry_type: 'consultation',
        source:       'website',
        name:         params[:name].to_s.strip,
        phone:        params[:phone].to_s.strip,
        email:        params[:email].to_s.strip.presence,
        message:      build_message(service),
        ip_address:   request.remote_ip,
        user_agent:   request.user_agent,
        metadata:     { service_slug: params[:service_slug], service_type_id: service&.id }.compact
      }
      attrs[:user_id] = current_user.id if user_signed_in?

      Inquiry.create!(attrs)

      respond_to do |format|
        format.html { redirect_to services_page_path, notice: 'Заявка получена. Менеджер свяжется с вами в ближайшее время.' }
        format.json { render json: { ok: true } }
      end
    rescue StandardError => e
      Rails.logger.error("Forms::ServiceRequest failed: #{e.class} #{e.message}")
      respond_to do |format|
        format.html { redirect_to services_page_path, alert: 'Не удалось отправить заявку. Попробуйте позже или позвоните нам.' }
        format.json { render json: { ok: false, error: e.message }, status: :unprocessable_entity }
      end
    end

    private

    def build_message(service)
      header = service ? "Заявка по услуге: #{service.title}" : "Запрос услуги: #{params[:service_slug]}"
      [header, params[:message].to_s.strip].compact_blank.join("\n\n")
    end
  end
end
