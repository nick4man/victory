# frozen_string_literal: true

require 'net/http'
require 'json'

module Telegram
  # Minimal Net::HTTP wrapper for Telegram Bot API.
  # Reads TELEGRAM_BOT_TOKEN from ENV; per-call chat_id passed explicitly.
  class Client
    class Error < StandardError; end

    BASE = 'https://api.telegram.org'

    def initialize(token: ENV['TELEGRAM_BOT_TOKEN'])
      raise Error, 'TELEGRAM_BOT_TOKEN not set' if token.blank?
      @token = token
    end

    # @return [Hash] Telegram message object on success ({message_id:, chat:, text:, ...})
    def send_message(text, chat_id:, reply_to_message_id: nil, parse_mode: 'HTML', disable_web_page_preview: true)
      body = {
        chat_id:                  chat_id,
        text:                     text,
        parse_mode:               parse_mode,
        disable_web_page_preview: disable_web_page_preview
      }
      body[:reply_to_message_id] = reply_to_message_id if reply_to_message_id
      api_call('sendMessage', body)
    end

    def get_me
      api_call('getMe')
    end

    def set_webhook(url, secret_token: nil)
      body = { url: url }
      body[:secret_token] = secret_token if secret_token
      api_call('setWebhook', body)
    end

    def delete_webhook
      api_call('deleteWebhook')
    end

    def webhook_info
      api_call('getWebhookInfo')
    end

    private

    def api_call(method, body = {})
      uri = URI("#{BASE}/bot#{@token}/#{method}")
      req = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
      req.body = JSON.generate(body) unless body.empty?

      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                            open_timeout: 5, read_timeout: 30) { |h| h.request(req) }
      data = JSON.parse(res.body) rescue {}
      raise Error, "Telegram #{method}: #{data['description'] || res.code}" unless data['ok']
      data['result']
    end
  end
end
