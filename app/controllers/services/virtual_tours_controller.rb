# frozen_string_literal: true

module Services
  class VirtualToursController < ApplicationController
    include ComingSoonSection

    def index
      render_coming_soon('Виртуальные туры', '3D-туры по объектам недвижимости. Раздел в разработке.')
    end

    def show
      render_coming_soon('Виртуальный тур')
    end

    def featured
      render_coming_soon('Избранные виртуальные туры')
    end
  end
end
