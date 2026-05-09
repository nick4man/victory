# frozen_string_literal: true

module Services
  class MortgageApplicationsController < ApplicationController
    include ComingSoonSection

    def new
      render_coming_soon('Заявка на ипотеку')
    end

    def create
      redirect_to root_path, notice: 'Заявка принята. Менеджер свяжется с вами.'
    end

    def show
      render_coming_soon('Статус заявки')
    end

    def status
      render_coming_soon('Статус заявки')
    end
  end
end
