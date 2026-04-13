# frozen_string_literal: true

class Sell::EvaluationsController < ApplicationController
  def show
    # Landing page for the online evaluation service
  end

  def new
    @valuation = PropertyValuation.new
  end

  def create
    redirect_to new_property_valuation_path
  end

  def result
    @valuation = PropertyValuation.find_by!(token: params[:token])
  rescue ActiveRecord::RecordNotFound
    redirect_to sell_evaluation_path, alert: 'Оценка не найдена'
  end
end
