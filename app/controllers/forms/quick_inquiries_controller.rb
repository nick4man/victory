# frozen_string_literal: true

module Forms
  class QuickInquiriesController < ApplicationController
    skip_before_action :verify_authenticity_token, only: [:create], raise: false

    def create
      Rails.logger.info("Forms::QuickInquiry: #{params.to_unsafe_h.except(:authenticity_token, :controller, :action)}")
      respond_to do |format|
        format.html { redirect_back fallback_location: root_path, notice: 'Заявка отправлена. Менеджер свяжется с вами.' }
        format.json { render json: { ok: true } }
      end
    end
  end
end
