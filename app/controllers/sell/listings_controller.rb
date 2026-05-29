# frozen_string_literal: true

module Sell
  class ListingsController < ApplicationController
    include ComingSoonSection

    def new
      render_coming_soon('Размещение объявления')
    end

    def create
      redirect_to root_path, notice: 'Спасибо! Скоро мы примем ваше объявление автоматически.'
    end

    def edit
      render_coming_soon('Редактирование объявления')
    end

    def update
      redirect_to root_path, notice: 'Изменения сохранены.'
    end

    def preview
      render_coming_soon('Предпросмотр')
    end

    def publish
      redirect_back fallback_location: root_path, notice: 'Опубликовано.'
    end

    def unpublish
      redirect_back fallback_location: root_path, notice: 'Снято с публикации.'
    end
  end
end
