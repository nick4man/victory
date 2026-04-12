# frozen_string_literal: true

class Sell::EvaluationsController < ApplicationController
  def new
    @valuation = PropertyValuation.new
  end

  def create
    redirect_to new_property_valuation_path
  end
end
