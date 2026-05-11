# frozen_string_literal: true

require 'net/http'
require 'json'
require 'securerandom'

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

    # Upload a binary document (PDF/etc) with optional caption via the
    # sendDocument Bot API endpoint. Uses multipart/form-data.
    # @param file can be:
    #   - Tempfile / File (uses #path + #read)
    #   - Hash { io: IO, filename: String, content_type: String }
    #   - String (path to file)
    def send_document(file, chat_id:, caption: nil, parse_mode: 'HTML')
      io, filename, content_type = unpack_file(file)
      content = io.read
      boundary = "----victory-#{SecureRandom.hex(8)}"

      parts = String.new(encoding: 'ASCII-8BIT')
      parts << form_field(boundary, 'chat_id', chat_id.to_s)
      if caption.present?
        parts << form_field(boundary, 'caption', caption.to_s)
        parts << form_field(boundary, 'parse_mode', parse_mode)
      end
      parts << form_file(boundary, 'document', filename, content_type, content)
      parts << "--#{boundary}--\r\n".b

      uri = URI("#{BASE}/bot#{@token}/sendDocument")
      req = Net::HTTP::Post.new(uri, 'Content-Type' => "multipart/form-data; boundary=#{boundary}")
      req.body = parts
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                            open_timeout: 5, read_timeout: 60) { |h| h.request(req) }
      data = JSON.parse(res.body) rescue {}
      raise Error, "Telegram sendDocument: #{data['description'] || res.code}" unless data['ok']
      data['result']
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

    def unpack_file(file)
      if file.is_a?(Hash)
        [file[:io], file[:filename] || 'document', file[:content_type] || 'application/octet-stream']
      elsif file.respond_to?(:path)
        [file, File.basename(file.path), 'application/octet-stream']
      elsif file.is_a?(String)
        [File.open(file, 'rb'), File.basename(file), 'application/octet-stream']
      else
        raise Error, "send_document: unsupported file type #{file.class}"
      end
    end

    def form_field(boundary, name, value)
      "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{name}\"\r\n\r\n#{value}\r\n".b
    end

    def form_file(boundary, name, filename, content_type, content)
      head = "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{name}\"; filename=\"#{filename}\"\r\n" \
             "Content-Type: #{content_type}\r\n\r\n".b
      head + content.dup.force_encoding('ASCII-8BIT') + "\r\n".b
    end

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
