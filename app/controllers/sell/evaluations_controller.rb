# frozen_string_literal: true

module Sell
  class EvaluationsController < ApplicationController
    include ComingSoonSection

    # Phase 4.5 — the /sell/evaluation stub is superseded by /valuations
    # (mode-picker: Express + Investment Audit). Redirect rather than show a
    # "coming soon" placeholder.
    def new
      redirect_to valuations_path, status: :moved_permanently
    end

    def create
      redirect_to valuations_path, notice: 'Перенаправляем на оценку.'
    end

    def show
      render_coming_soon('Продать недвижимость')
    end

    def result
      render_coming_soon('Результат оценки')
    end
  end
end
