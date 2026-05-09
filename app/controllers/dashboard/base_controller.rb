# frozen_string_literal: true

module Dashboard
  class BaseController < ApplicationController
    include ComingSoonSection
    before_action :authenticate_user!

    # layouts/dashboard.html.erb requires precompiled application.css; until Tailwind
    # is wired through Sprockets, fall back to the application layout (which loads CSS via CDN/inline).
    layout 'application'
  end
end
