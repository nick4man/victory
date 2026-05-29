# frozen_string_literal: true

require 'cgi'

module Articles
  # Posts an Article to the @rznvictory Telegram channel via @victory62_bot
  # (reuses `Telegram::Client` + `ENV['TELEGRAM_BOT_TOKEN']`).
  #
  # Flow:
  #   1. Bail out if already posted (article.metadata['telegram_message_id'] present).
  #   2. Build text — bold title, excerpt, link back to /news, hashtags.
  #   3. If article has image_url in metadata → sendPhoto with caption.
  #      Otherwise → sendMessage with text.
  #   4. Save telegram_message_id + telegram_published_at + telegram_channel_id
  #      back into article.metadata so the kbd never double-posts and the
  #      admin form can show "✓ опубликовано".
  #
  # Returns:
  #   { success: true,  message_id: <int>, posted_at: <Time> }
  #   { success: false, error: <string>, message_id: <int|nil> }
  class TelegramPublisher
    MAX_CAPTION = 1024  # Telegram sendPhoto caption hard limit
    MAX_MESSAGE = 4096  # Telegram sendMessage text hard limit

    def initialize(article, channel_id: nil)
      @article    = article
      @channel_id = channel_id.presence ||
                    ENV['TELEGRAM_NEWS_CHANNEL_ID'].presence ||
                    '@rznvictory'
    end

    def call
      return already_posted if posted?

      response = if image_url.present?
                   client.send_photo(@channel_id, image_url, caption: build_caption, parse_mode: 'HTML')
                 else
                   client.send_message(build_text, chat_id: @channel_id, parse_mode: 'HTML',
                                                   disable_web_page_preview: false)
                 end
      message_id = response.is_a?(Hash) ? response['message_id'] : nil
      raise Telegram::Client::Error, 'no message_id in response' unless message_id

      save_marker!(message_id)
      { success: true, message_id: message_id, posted_at: Time.current }
    rescue Telegram::Client::Error => e
      Rails.logger.warn("[Articles::TelegramPublisher] article=#{@article.id}: #{e.message}")
      { success: false, error: e.message }
    end

    private

    def client
      @client ||= Telegram::Client.new
    end

    def posted?
      @article.metadata.is_a?(Hash) && @article.metadata['telegram_message_id'].present?
    end

    def already_posted
      { success: false, error: 'already_posted', message_id: @article.metadata['telegram_message_id'] }
    end

    def image_url
      @article.metadata.is_a?(Hash) ? @article.metadata['image_url'].to_s.presence : nil
    end

    # Telegram HTML supports <b>, <i>, <u>, <s>, <a>, <code>, <pre>. Other
    # markup gets stripped silently by Telegram; we escape every < to keep
    # user-supplied content (title/excerpt) from accidentally breaking
    # the message.
    def build_text
      lines = []
      lines << "<b>#{esc(@article.title)}</b>"
      lines << ''
      body_summary = @article.excerpt.presence || safe_excerpt
      lines << esc(body_summary) if body_summary.present?
      lines << ''
      lines << "Подробнее → #{article_url}"
      tags = clean_hashtags
      if tags.any?
        lines << ''
        lines << tags.map { |t| "##{t}" }.join(' ')
      end
      lines.join("\n")[0, MAX_MESSAGE]
    end

    def build_caption
      build_text[0, MAX_CAPTION]
    end

    def safe_excerpt
      @article.respond_to?(:short_excerpt) ? @article.short_excerpt(length: 600) : ''
    end

    def article_url
      Rails.application.routes.url_helpers.news_url(
        article: @article.slug,
        host:    'victory62.org',
        protocol: 'https'
      )
    rescue StandardError
      "https://victory62.org/news?article=#{@article.slug}"
    end

    def clean_hashtags
      raw = @article.metadata.is_a?(Hash) ? @article.metadata['hashtags'] : nil
      Array(raw).map { |t| t.to_s.delete_prefix('#').strip }.reject(&:blank?)
    end

    def save_marker!(message_id)
      new_meta = (@article.metadata || {}).merge(
        'telegram_message_id'   => message_id,
        'telegram_published_at' => Time.current.iso8601,
        'telegram_channel_id'   => @channel_id
      )
      @article.update_column(:metadata, new_meta)
    end

    def esc(str)
      CGI.escapeHTML(str.to_s)
    end
  end
end
