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
    @news_carousel = recent_news_for_carousel
  end

  private

  # Strict last-24h news/market window — carousel is for «that just happened»,
  # not evergreen. Empty result hides the carousel (partial returns early on
  # blank). Quiet day = no strip. Cap at 5 slides to keep the cycle digestible.
  def recent_news_for_carousel
    Article.public_facing
           .where(category: %w[news market])
           .where('published_at > ?', 24.hours.ago)
           .limit(5)
           .to_a
  end
end
