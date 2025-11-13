# frozen_string_literal: true

class LandingController < ApplicationController
  skip_before_action :set_locale, raise: false
  layout false  # Don't use application layout - view has complete HTML
  
  def index
    # Minimal landing page with static data for design work
    # No database or gem dependencies required
    render :index
  end
end
