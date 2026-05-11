# frozen_string_literal: true

class LandingController < ApplicationController
  skip_before_action :set_locale, raise: false

  def index
    # Renders under application.html.erb so canonical / hreflang / geo /
    # JSON-LD / yandex-maps-api-key / shared header & footer are inherited.
    @metrics = AgencyMetricsService.call
    @reviews = Review.public_facing.limit(6).to_a
    # Latest news snippet above the featured-properties grid. Only news/market
    # categories (mortgage/investment articles tend to be evergreen guides
    # less suitable for the «that just happened» framing).
    @news_hero = Article.public_facing.where(category: %w[news market]).first
  end
end
