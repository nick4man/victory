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
      Disallow: /feeds/
      Disallow: /*?utm_*
      Disallow: /*?ref=*

      # Yandex's main bot — Crawl-delay tells it to pace requests, which
      # MatrixNet uses as a quality signal for server responsiveness.
      User-agent: YandexBot
      Allow: /
      Crawl-delay: 1

      # Mail.ru search — small but real RU audience for недвижимость queries.
      User-agent: Mail.RU_Bot
      Allow: /
      Crawl-delay: 2

      User-agent: Googlebot
      Allow: /

      # Bing covers DuckDuckGo + Yahoo as well — small RU share but free wins.
      User-agent: bingbot
      Allow: /

      # AI training crawlers: allowed for now (the plan says monitor, don't
      # block by default). Re-evaluate if logs show abusive volume.
      User-agent: GPTBot
      Allow: /
      Crawl-delay: 5

      User-agent: ClaudeBot
      Allow: /
      Crawl-delay: 5

      User-agent: PerplexityBot
      Allow: /
      Crawl-delay: 5

      # SEO-research scrapers — they re-index our catalog repeatedly and
      # skew log analytics without sending any real traffic.
      User-agent: AhrefsBot
      Disallow: /

      User-agent: SemrushBot
      Disallow: /

      User-agent: MJ12bot
      Disallow: /

      User-agent: DotBot
      Disallow: /

      User-agent: BLEXBot
      Disallow: /

      Sitemap: #{sitemap_url}
      Host: #{request.protocol}#{request.host_with_port}
    ROBOTS
    render plain: body, content_type: 'text/plain'
  end
end
