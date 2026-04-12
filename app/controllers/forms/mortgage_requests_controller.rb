# frozen_string_literal: true

class Forms::MortgageRequestsController < ApplicationController
  def create
    render json: { success: true, message: 'Заявка на ипотеку принята. Мы свяжемся с вами!' }
  end
end
