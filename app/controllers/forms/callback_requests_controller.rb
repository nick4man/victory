# frozen_string_literal: true

module Forms
  class CallbackRequestsController < ApplicationController
    skip_before_action :verify_authenticity_token, only: [:create], raise: false

    def create
      Rails.logger.info("Forms::CallbackRequest: #{params.to_unsafe_h.except(:authenticity_token, :controller, :action)}")
      respond_to do |format|
        format.html { redirect_back fallback_location: root_path, notice: 'Мы перезвоним вам в ближайшее время.' }
        format.json { render json: { ok: true } }
      end
    end
  end
end
