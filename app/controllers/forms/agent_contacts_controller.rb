# frozen_string_literal: true

module Forms
  class AgentContactsController < ApplicationController
    skip_before_action :verify_authenticity_token, only: [:create], raise: false

    def create
      # DLP-safe: log presence-flags only, never raw PII (phone/email/text).
      # Original unsafe-hash dump leaked raw values bypassing filter_parameters.
      Rails.logger.info(
        "[Forms::AgentContacts] submission " \
        "ip=#{request.remote_ip} " \
        "has_phone=#{params[:phone].present?} " \
        "has_email=#{params[:email].present?} " \
        "has_message=#{params[:message].present?}"
      )
      respond_to do |format|
        format.html { redirect_back fallback_location: root_path, notice: 'Сообщение отправлено агенту.' }
        format.json { render json: { ok: true } }
      end
    end
  end
end
