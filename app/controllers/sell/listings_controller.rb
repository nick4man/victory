# frozen_string_literal: true

class Sell::ListingsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_listing, only: [:edit, :update, :preview, :publish, :unpublish]

  def new
    @property = current_user.properties.new
  end

  def create
    @property = current_user.properties.new(listing_params)
    if params[:draft].present?
      @property.status = :draft
    else
      @property.status = :pending
    end

    if @property.save
      redirect_to property_path(@property), notice: 'Объявление успешно создано и отправлено на модерацию'
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @property.update(listing_params)
      redirect_to property_path(@property), notice: 'Объявление обновлено'
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def preview
    render :preview
  end

  def publish
    if @property.publish!
      redirect_to property_path(@property), notice: 'Объявление опубликовано'
    else
      redirect_to property_path(@property), alert: 'Не удалось опубликовать объявление'
    end
  end

  def unpublish
    if @property.unpublish!
      redirect_to property_path(@property), notice: 'Объявление снято с публикации'
    else
      redirect_to property_path(@property), alert: 'Не удалось снять объявление'
    end
  end

  private

  def set_listing
    @property = current_user.properties.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to dashboard_path, alert: 'Объявление не найдено'
  end

  def listing_params
    params.require(:property).permit(
      :title, :description, :price, :deal_type, :area, :living_area,
      :kitchen_area, :rooms, :bedrooms, :bathrooms, :floor, :total_floors,
      :building_year, :building_type, :condition, :address, :district,
      :metro_station, :metro_distance, :metro_transport,
      :has_balcony, :has_loggia, :has_parking, :has_elevator,
      :has_garbage_chute, :has_security, :has_concierge, :pets_allowed,
      :has_gas, :has_water, :has_electricity, :has_heating,
      :property_type_id, images: []
    )
  end
end
