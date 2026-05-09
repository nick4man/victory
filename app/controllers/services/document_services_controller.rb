# frozen_string_literal: true

module Services
  class DocumentServicesController < ApplicationController
    include ComingSoonSection

    def index
      render_coming_soon('Помощь с документами')
    end

    def request_service
      redirect_back fallback_location: root_path, notice: 'Запрос отправлен.'
    end
  end
end
