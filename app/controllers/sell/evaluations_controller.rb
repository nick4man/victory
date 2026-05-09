# frozen_string_literal: true

module Sell
  class EvaluationsController < ApplicationController
    include ComingSoonSection

    def new
      render_coming_soon('Продать недвижимость', 'Бесплатная экспресс-оценка вашего объекта. Раздел в разработке — пока вы можете воспользоваться <a href="/valuations/new" class="underline">детальной онлайн-оценкой</a>.'.html_safe)
    end

    def create
      redirect_to new_property_valuation_path, notice: 'Перенаправляем в детальную оценку.'
    end

    def show
      render_coming_soon('Продать недвижимость')
    end

    def result
      render_coming_soon('Результат оценки')
    end
  end
end
