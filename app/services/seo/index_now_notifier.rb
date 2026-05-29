# frozen_string_literal: true

# Notifies the IndexNow endpoint when listings/articles are published or
# significantly updated. Supported search engines: Bing, Yandex, Brave (Yep),
# Naver, Seznam, DuckDuckGo (Google does NOT support IndexNow — use Search
# Console for Google).
#
# See .claude/docs/seo/indexnow-setup.md for the full setup guide.
module Seo
  class IndexNowNotifier
    ENDPOINT = 'https://api.indexnow.org/indexnow'
    HOST     = 'victory62.org'
    BATCH    = 10_000

    def initialize(urls)
      @urls = Array(urls).compact_blank.uniq
    end

    def call
      api_key = ENV['INDEXNOW_API_KEY']
      return :skip if api_key.blank? || @urls.empty?
      return :skip unless Rails.env.production?

      body = {
        host:        HOST,
        key:         api_key,
        keyLocation: "https://#{HOST}/#{api_key}.txt",
        urlList:     @urls.first(BATCH)
      }

      response = Faraday.post(ENDPOINT, body.to_json, 'Content-Type' => 'application/json')
      Rails.logger.info("[IndexNow] #{response.status} for #{@urls.size} URL(s)")
      response.status
    rescue StandardError => e
      Rails.logger.warn("[IndexNow] failed: #{e.class} #{e.message}")
      nil
    end
  end
end
