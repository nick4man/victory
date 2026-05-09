# frozen_string_literal: true

module Sell
  class PlansController < ApplicationController
    include ComingSoonSection

    def index
      render_coming_soon('Тарифы размещения')
    end

    def show
      render_coming_soon('Тариф')
    end
  end
end
