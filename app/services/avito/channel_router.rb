# frozen_string_literal: true

module Avito
  # Routes a parsed inbound AvitoMessage to the configured channel.
  #
  # Currently supported channels:
  #   * telegram — sends a notification to AVITO_TELEGRAM_CHAT_ID (falls back
  #     to TELEGRAM_STAFF_CHAT_ID).
  #
  # The router is intentionally thin: formatting lives here, network errors are
  # logged, and the exception is re-raised so Sidekiq can retry.
  class ChannelRouter
    def initialize(message, client: Telegram::Client.new)
      @message = message
      @client  = client
    end

    def call
      case channel_name
      when 'telegram', nil, ''
        route_to_telegram
      else
        Rails.logger.warn("[Avito::ChannelRouter] unknown channel '#{channel_name}'")
        :unknown_channel
      end
    end

    private

    def channel_name
      ENV['AVITO_TARGET_CHANNEL'].to_s.downcase.strip
    end

    def route_to_telegram
      chat_id = target_chat_id
      return :no_chat_id if chat_id.blank?

      result = deliver_to_telegram(chat_id)
      @message.update!(routed_at: Time.current)
      result
    rescue Telegram::Client::Error => e
      Rails.logger.error("[Avito::ChannelRouter] Telegram error: #{e.message}")
      raise
    end

    def target_chat_id
      ENV['AVITO_TELEGRAM_CHAT_ID'].presence || ENV['TELEGRAM_STAFF_CHAT_ID'].presence
    end

    def deliver_to_telegram(chat_id)
      if @message.content_type == 'image' && image_url.present?
        @client.send_photo(chat_id, image_url, caption: caption_text, parse_mode: 'HTML')
      else
        @client.send_message(text_message, chat_id: chat_id, parse_mode: 'HTML')
      end
    end

    def text_message
      lines = []
      lines << "📨 <b>Avito</b> #{object_line}"
      lines << ''
      lines << "👤 #{I18n.t('avito.channel.buyer', id: @message.author_id)}"
      lines << "💬 #{escape(@message.content_text.to_s)}" if @message.content_text.present?
      lines << ''
      lines << "▶️ #{I18n.t('avito.channel.reply_hint')}"
      lines.join("\n")
    end

    def caption_text
      lines = ["📨 Avito #{object_line_plain}"]
      lines << "👤 #{I18n.t('avito.channel.buyer', id: @message.author_id)}"
      lines << "💬 #{escape(@message.content_text.to_s)}" if @message.content_text.present?
      lines.join("\n")
    end

    def object_line
      if @message.property
        "<a href=\"#{property_url}\">#{escape(@message.property.title.to_s)}</a>"
      else
        "<code>#{@message.item_id}</code>"
      end
    end

    def object_line_plain
      if @message.property
        "#{escape(@message.property.title.to_s)} (#{property_url})"
      else
        "item_id: #{@message.item_id}"
      end
    end

    def property_url
      Rails.application.routes.url_helpers.property_url(@message.property, host: ENV.fetch('APP_DOMAIN', 'victory62.org'))
    end

    def image_url
      sizes = @message.payload.dig('content', 'image', 'sizes') || {}
      sizes['1280x960'].presence || sizes['640x480'].presence || sizes.values.first.to_s.presence
    end

    def escape(text)
      text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
    end
  end
end
