# frozen_string_literal: true

class Forms::ConsultationRequestsController < ApplicationController
  def create
    render json: { success: true, message: 'Заявка на консультацию принята' }
  end
end
