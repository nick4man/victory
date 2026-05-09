# frozen_string_literal: true

class RobotsController < ApplicationController
  def index
    body = <<~ROBOTS
      User-agent: *
      Disallow: /dashboard
      Disallow: /users/
      Disallow: /api/
      Disallow: /sidekiq
      Allow: /

      Sitemap: #{request.protocol}#{request.host_with_port}/sitemap.xml
    ROBOTS
    render plain: body, content_type: 'text/plain'
  end
end
