# frozen_string_literal: true

module Services
  class LegalServicesController < ApplicationController
    include ComingSoonSection

    def index
      render_coming_soon('Юридические услуги', 'Сопровождение сделок, проверка документов, регистрация прав.')
    end

    def show
      render_coming_soon('Юридическая услуга')
    end

    def request_service
      redirect_back fallback_location: root_path, notice: 'Запрос отправлен.'
    end
  end
end
