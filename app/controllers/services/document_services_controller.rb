# frozen_string_literal: true

class Services::DocumentServicesController < ApplicationController
  def index
  end

  def show
  end

  def submit_request
    render json: { success: true, message: 'Заявка принята' }
  end
end
