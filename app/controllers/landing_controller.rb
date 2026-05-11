# frozen_string_literal: true

class LandingController < ApplicationController
  skip_before_action :set_locale, raise: false

  def index
    # Renders under application.html.erb so canonical / hreflang / geo /
    # JSON-LD / yandex-maps-api-key / shared header & footer are inherited.
    @metrics = AgencyMetricsService.call
    @reviews = Review.public_facing.limit(6).to_a
  end
end
