# frozen_string_literal: true

class ErrorsController < ApplicationController
  skip_before_action :setup_meta_tags, raise: false

  def not_found
    render status: :not_found, plain: 'Страница не найдена'
  end

  def unprocessable_entity
    render status: :unprocessable_entity, plain: 'Невозможно обработать запрос'
  end

  def internal_server_error
    render status: :internal_server_error, plain: 'Внутренняя ошибка сервера'
  end
end
