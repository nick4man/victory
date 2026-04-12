# frozen_string_literal: true

class Forms::ViewingRequestsController < ApplicationController
  def create
    render json: { success: true, message: 'Заявка на просмотр принята' }
  end
end
