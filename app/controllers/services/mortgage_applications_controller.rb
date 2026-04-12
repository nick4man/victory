# frozen_string_literal: true

class Services::MortgageApplicationsController < ApplicationController
  def new
  end

  def create
    redirect_to services_mortgage_calculator_path, notice: 'Заявка на ипотеку отправлена. Мы свяжемся с вами!'
  end

  def show
    redirect_to services_mortgage_calculator_path
  end

  def status
    render json: { status: 'pending' }
  end
end
