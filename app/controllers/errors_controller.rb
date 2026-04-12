# frozen_string_literal: true

class ErrorsController < ApplicationController
  layout 'application'

  def not_found
    respond_to do |format|
      format.html { render status: :not_found }
      format.json { render json: { error: 'Не найдено' }, status: :not_found }
      format.any  { head :not_found }
    end
  end

  def unprocessable_entity
    respond_to do |format|
      format.html { render status: :unprocessable_entity }
      format.json { render json: { error: 'Некорректный запрос' }, status: :unprocessable_entity }
      format.any  { head :unprocessable_entity }
    end
  end

  def internal_server_error
    respond_to do |format|
      format.html { render status: :internal_server_error }
      format.json { render json: { error: 'Внутренняя ошибка сервера' }, status: :internal_server_error }
      format.any  { head :internal_server_error }
    end
  end
end
