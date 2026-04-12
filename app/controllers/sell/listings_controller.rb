# frozen_string_literal: true

class Sell::ListingsController < ApplicationController
  def new
    @property = Property.new
  end

  def create
    redirect_to new_property_path
  end
end
