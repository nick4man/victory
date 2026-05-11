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

  # Up to 5 news/market articles from the last 24h. Falls back to the 3 most
  # recent in those categories if the past day was quiet — never want the
  # carousel to vanish completely if there's any newsroom output.
  def recent_news_for_carousel
    recent = Article.public_facing
                    .where(category: %w[news market])
                    .where('published_at > ?', 24.hours.ago)
                    .limit(5)
                    .to_a
    return recent if recent.size >= 2
    Article.public_facing.where(category: %w[news market]).limit(3).to_a
  end
end
