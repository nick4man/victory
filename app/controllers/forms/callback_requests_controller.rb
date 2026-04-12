# frozen_string_literal: true

class Forms::CallbackRequestsController < ApplicationController
  def create
    render json: { success: true, message: 'Мы перезвоним вам в ближайшее время' }
  end
end
