# frozen_string_literal: true

module Forms
  class ViewingRequestsController < ApplicationController
    skip_before_action :verify_authenticity_token, only: [:create], raise: false

    def create
      Rails.logger.info("Forms::ViewingRequest: #{params.to_unsafe_h.except(:authenticity_token, :controller, :action)}")
      respond_to do |format|
        format.html { redirect_back fallback_location: root_path, notice: 'Запрос на показ принят.' }
        format.json { render json: { ok: true } }
      end
    end
  end
end
