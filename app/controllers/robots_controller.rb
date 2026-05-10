# frozen_string_literal: true

# Serves /robots.txt. Splits rules per crawler so we can:
#   • allow Googlebot/YandexBot fully (with Yandex's preferred Crawl-delay)
#   • block aggressive SEO scrapers (Ahrefs, Semrush) — they re-index our
#     entire catalog repeatedly and skew our log analytics
#   • disallow dashboard/api routes from generic crawlers
class RobotsController < ApplicationController
  def index
    sitemap_url = "#{request.protocol}#{request.host_with_port}/sitemap.xml"
    body = <<~ROBOTS
      User-agent: *
      Allow: /
      Disallow: /admin/
      Disallow: /dashboard/
      Disallow: /api/
      Disallow: /users/
      Disallow: /sidekiq/
      Disallow: /search?
      Disallow: /*?utm_*
      Disallow: /*?ref=*

      User-agent: YandexBot
      Allow: /
      Crawl-delay: 1

      User-agent: Googlebot
      Allow: /

      User-agent: AhrefsBot
      Disallow: /

      User-agent: SemrushBot
      Disallow: /

      User-agent: MJ12bot
      Disallow: /

      User-agent: DotBot
      Disallow: /

      Sitemap: #{sitemap_url}
      Host: #{request.protocol}#{request.host_with_port}
    ROBOTS
    render plain: body, content_type: 'text/plain'
  end
end
