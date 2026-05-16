# frozen_string_literal: true

module Telegram
  # Saves Telegram messages from whitelisted senders (operator personal
  # account + Oksana + ops group) into the local /app/inbox/ directory so
  # Claude / staff can review screenshots and notes between sessions.
  #
  # Whitelist comes from ENV[TELEGRAM_INBOX_WHITELIST] — comma-separated
  # numeric chat_ids. Both private chats (positive ids) and groups
  # (negative ids) supported. If the env var is unset, the saver is a no-op
  # — it WILL NOT save messages from random Telegram users.
  #
  # Storage layout (gitignored):
  #   inbox/
  #     2026-05-12_18-30-15_id<chat_id>_msg<message_id>.json    # always
  #     2026-05-12_18-30-15_id<chat_id>_msg<message_id>.jpg     # if photo
  #     2026-05-12_18-30-15_id<chat_id>_msg<message_id>.<ext>   # if document
  class InboxSaver
    INBOX_DIR = Rails.root.join('inbox')

    def initialize(msg)
      @msg = msg
    end

    def self.call(msg)
      new(msg).call
    end

    # Fast whitelist check without instantiating — used by InboundProcessor
    # to decide whether to enqueue the async TelegramInboxSaveJob at all.
    def self.whitelisted?(msg)
      return false if msg.blank?
      list = ENV['TELEGRAM_INBOX_WHITELIST'].to_s.split(',').map { |s| s.strip.to_i }.compact_blank
      return false if list.empty?
      chat_id = msg.dig('chat', 'id').to_i
      from_id = msg.dig('from', 'id').to_i
      list.include?(chat_id) || list.include?(from_id)
    end

    def call
      return :no_msg if @msg.blank?
      return :not_whitelisted unless whitelisted?

      ensure_dir
      base = filename_base
      write_meta!(base)
      write_text!(base) if text.present?
      download_photo!(base) if photo.present?
      download_document!(base) if document.present?

      Rails.logger.info("[Telegram::InboxSaver] saved #{base}")
      :saved
    rescue StandardError => e
      Rails.logger.warn("[Telegram::InboxSaver] failed: #{e.class} #{e.message}")
      :error
    end

    private

    def whitelist
      ENV['TELEGRAM_INBOX_WHITELIST'].to_s.split(',').map { |s| s.strip.to_i }.compact_blank
    end

    def chat_id
      @msg.dig('chat', 'id').to_i
    end

    def from_id
      @msg.dig('from', 'id').to_i
    end

    def whitelisted?
      list = whitelist
      return false if list.empty?
      list.include?(chat_id) || list.include?(from_id)
    end

    def text
      @msg['text'].presence || @msg['caption'].presence
    end

    # Telegram sends photos as an array of progressively larger thumbnails;
    # the last entry is the original-resolution version. We grab that one.
    def photo
      Array(@msg['photo']).last
    end

    def document
      @msg['document']
    end

    def ensure_dir
      INBOX_DIR.mkpath
    end

    def filename_base
      ts = Time.current.strftime('%Y-%m-%d_%H-%M-%S')
      "#{ts}_id#{chat_id}_msg#{@msg['message_id']}"
    end

    def write_meta!(base)
      File.write(INBOX_DIR.join("#{base}.json"), JSON.pretty_generate({
        message_id:  @msg['message_id'],
        date:        @msg['date'],
        chat:        @msg['chat'],
        from:        @msg['from'],
        text:        @msg['text'],
        caption:     @msg['caption'],
        photo_meta:  photo,
        document_meta: document,
        ingested_at: Time.current.iso8601
      }.compact))
    end

    def write_text!(base)
      File.write(INBOX_DIR.join("#{base}.txt"), text)
    end

    def download_photo!(base)
      client.download_file_to(photo['file_id'], INBOX_DIR.join("#{base}.jpg"))
    end

    def download_document!(base)
      ext = File.extname(document['file_name'].to_s).presence || '.bin'
      client.download_file_to(document['file_id'], INBOX_DIR.join("#{base}#{ext}"))
    end

    def client
      @client ||= Telegram::Client.new
    end
  end
end
