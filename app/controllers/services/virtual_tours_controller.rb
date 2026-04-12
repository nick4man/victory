# frozen_string_literal: true

class Services::VirtualToursController < ApplicationController
  def index
    @properties = Property.published.with_virtual_tour.includes(:property_type).limit(20)
  end

  def show
    @property = Property.published.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to services_virtual_tours_path, alert: 'Тур не найден'
  end
end
