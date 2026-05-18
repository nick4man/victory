# frozen_string_literal: true

require 'net/http'
require 'json'
require 'securerandom'
require 'tempfile'

module Telegram
  # Minimal Net::HTTP wrapper for Telegram Bot API.
  # Reads TELEGRAM_BOT_TOKEN from ENV; per-call chat_id passed explicitly.
  class Client
    class Error < StandardError; end

    BASE = 'https://api.telegram.org'

    def initialize(token: ENV.fetch('TELEGRAM_BOT_TOKEN', nil))
      raise Error, 'TELEGRAM_BOT_TOKEN not set' if token.blank?

      @token = token
    end

    # @return [Hash] Telegram message object on success ({message_id:, chat:, text:, ...})
    # @param message_thread_id [Integer, nil] id топика форум-группы (для постов в конкретный топик)
    # @param reply_markup [Hash, nil] payload inline-клавиатуры (Telegram сериализует сам)
    def send_message(text, chat_id:, reply_to_message_id: nil, message_thread_id: nil,
                     reply_markup: nil, parse_mode: 'HTML', disable_web_page_preview: true)
      body = {
        chat_id: chat_id,
        text: text,
        parse_mode: parse_mode,
        disable_web_page_preview: disable_web_page_preview
      }
      body[:reply_to_message_id] = reply_to_message_id if reply_to_message_id
      body[:message_thread_id]   = message_thread_id   if message_thread_id
      body[:reply_markup]        = reply_markup        if reply_markup
      api_call('sendMessage', body)
    end

    # Редактирование текста и/или клавиатуры существующего сообщения бота.
    # Используется для обновления карточки лида после /assign, /stage и т.п.
    def edit_message_text(text, chat_id:, message_id:, reply_markup: nil,
                          parse_mode: 'HTML', disable_web_page_preview: true)
      body = {
        chat_id: chat_id,
        message_id: message_id,
        text: text,
        parse_mode: parse_mode,
        disable_web_page_preview: disable_web_page_preview
      }
      body[:reply_markup] = reply_markup if reply_markup
      api_call('editMessageText', body)
    end

    # Phase 12 Iter 34 — отдельный endpoint для удаления только клавиатуры
    # без edit'а текста. Используется в /reassign чтобы инвалидировать stale
    # inline-кнопки в старой DM-карточке assignee (текст не трогаем — он
    # уже multiline + содержит history задачи).
    def edit_message_reply_markup(chat_id:, message_id:, reply_markup:)
      api_call('editMessageReplyMarkup',
               chat_id: chat_id,
               message_id: message_id,
               reply_markup: reply_markup)
    end

    # Удаление сообщения. Бот может удалить любое сообщение в группе с can_delete_messages,
    # либо своё в течение 48ч. Telegram возвращает true либо ошибку.
    def delete_message(chat_id:, message_id:)
      api_call('deleteMessage', chat_id: chat_id, message_id: message_id)
    rescue Error => e
      # Сообщение уже удалено / не существует / слишком старое — это не критично, логируем.
      Rails.logger.warn("[Telegram] deleteMessage failed (chat=#{chat_id} msg=#{message_id}): #{e.message}")
      nil
    end

    # Ответ на нажатие inline-кнопки. БЕЗ этого вызова у пользователя крутится спиннер.
    # `text` — короткое уведомление (toast); `show_alert=true` — модальное окно вместо toast.
    def answer_callback_query(callback_query_id, text: nil, show_alert: false)
      body = { callback_query_id: callback_query_id, show_alert: show_alert }
      body[:text] = text if text.present?
      api_call('answerCallbackQuery', body)
    end

    # Закрепление сообщения в чате/топике. Нужен can_pin_messages.
    def pin_chat_message(chat_id:, message_id:, disable_notification: true)
      api_call('pinChatMessage',
               chat_id: chat_id,
               message_id: message_id,
               disable_notification: disable_notification)
    end

    # Открепить конкретное сообщение (или последнее закрепленное, если message_id nil).
    # Telegram возвращает true. Если оно уже unpin'нуто — TG отвечает 400, мы swallow'ем.
    def unpin_chat_message(chat_id:, message_id: nil)
      body = { chat_id: chat_id }
      body[:message_id] = message_id if message_id
      api_call('unpinChatMessage', body)
    rescue Error => e
      Rails.logger.warn("[Telegram] unpin failed (chat=#{chat_id} msg=#{message_id}): #{e.message}")
      nil
    end

    # Upload a binary document (PDF/etc) with optional caption via the
    # sendDocument Bot API endpoint. Uses multipart/form-data.
    # @param file can be:
    #   - Tempfile / File (uses #path + #read)
    #   - Hash { io: IO, filename: String, content_type: String }
    #   - String (path to file)
    def send_document(file, chat_id:, caption: nil, parse_mode: 'HTML',
                      reply_to_message_id: nil, message_thread_id: nil)
      io, filename, content_type = unpack_file(file)
      content = io.read
      boundary = "----victory-#{SecureRandom.hex(8)}"

      parts = String.new(encoding: 'ASCII-8BIT')
      parts << form_field(boundary, 'chat_id', chat_id.to_s)
      parts << form_field(boundary, 'message_thread_id', message_thread_id.to_s) if message_thread_id
      parts << form_field(boundary, 'reply_to_message_id', reply_to_message_id.to_s) if reply_to_message_id
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
      data = begin
        JSON.parse(res.body)
      rescue StandardError
        {}
      end
      raise Error, "Telegram sendDocument: #{data['description'] || res.code}" unless data['ok']

      data['result']
    end

    # Post a photo via URL (Telegram fetches it server-side) with optional
    # caption. Caption max length is 1024 characters per Telegram API — caller
    # is responsible for trimming.
    def send_photo(chat_id, photo_url, caption: nil, parse_mode: 'HTML',
                   message_thread_id: nil, reply_markup: nil)
      body = { chat_id: chat_id, photo: photo_url, parse_mode: parse_mode }
      body[:caption]           = caption           if caption.present?
      body[:message_thread_id] = message_thread_id if message_thread_id
      body[:reply_markup]      = reply_markup      if reply_markup
      api_call('sendPhoto', body)
    end

    def get_me
      api_call('getMe')
    end

    def set_webhook(url, secret_token: nil, allowed_updates: nil, drop_pending_updates: nil)
      body = { url: url }
      body[:secret_token]        = secret_token        if secret_token
      body[:allowed_updates]     = allowed_updates     if allowed_updates
      body[:drop_pending_updates] = drop_pending_updates unless drop_pending_updates.nil?
      api_call('setWebhook', body)
    end

    def delete_webhook
      api_call('deleteWebhook')
    end

    def webhook_info
      api_call('getWebhookInfo')
    end

    # getFile → metadata about a file uploaded to TG (voice/photo/document).
    # Returns Hash { file_id, file_unique_id, file_size, file_path } или nil.
    # file_path валиден ~1 час; для долгосрочного хранения файл надо скачать.
    def get_file(file_id)
      api_call('getFile', file_id: file_id)
    rescue Error => e
      Rails.logger.warn("[Telegram] getFile failed (file_id=#{file_id}): #{e.message}")
      nil
    end

    # Скачать file_id в локальный Tempfile. Caller отвечает за #close + #unlink
    # после использования (или использовать в блоке/begin-ensure).
    #
    # @return [Tempfile, nil] open Tempfile (rewound to start) или nil если getFile упал
    def download_file(file_id, prefix: 'tg-download')
      meta = get_file(file_id)
      remote_path = meta&.dig('file_path')
      return nil if remote_path.blank?

      ext = File.extname(remote_path).presence || '.bin'
      tmp = Tempfile.new([prefix, ext], binmode: true)
      stream_to_io(remote_path, tmp)
      tmp.rewind
      tmp
    rescue StandardError => e
      Rails.logger.warn("[Telegram] download_file failed (file_id=#{file_id}): #{e.class} #{e.message}")
      nil
    end

    # Скачать file_id напрямую в указанный path (для InboxSaver).
    def download_file_to(file_id, local_path)
      meta = get_file(file_id)
      remote_path = meta&.dig('file_path')
      return nil if remote_path.blank?

      File.open(local_path, 'wb') { |f| stream_to_io(remote_path, f) }
      local_path
    end

    # Pull pending updates. Useful when webhook is blocked / for one-off drain.
    # Telegram REQUIRES webhook deleted before calling getUpdates (409 conflict
    # otherwise) — caller is responsible for orchestrating delete→get→set.
    # @param offset [Integer] update_id to start from (use last_id + 1)
    # @param limit  [Integer] 1-100
    # @param timeout [Integer] long-polling seconds (0 = short poll)
    def get_updates(offset: 0, limit: 100, timeout: 0)
      api_call('getUpdates', offset: offset, limit: limit, timeout: timeout)
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

    # Низкоуровневое стримирование файла Telegram → произвольный IO (File / Tempfile).
    # Не создаёт IO и не закрывает его — caller отвечает за lifecycle.
    def stream_to_io(remote_path, io)
      uri = URI("#{BASE}/file/bot#{@token}/#{remote_path}")
      Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                                          open_timeout: 5, read_timeout: 60) do |http|
        http.request(Net::HTTP::Get.new(uri)) do |response|
          raise Error, "Telegram file download: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

          response.read_body { |chunk| io.write(chunk) }
        end
      end
      io
    end

    def api_call(method, body = {}, retried: false)
      uri = URI("#{BASE}/bot#{@token}/#{method}")
      req = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
      req.body = JSON.generate(body) unless body.empty?

      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                                                open_timeout: 5, read_timeout: 30) { |h| h.request(req) }
      data = begin
        JSON.parse(res.body)
      rescue StandardError
        {}
      end

      # Phase 13 Iter 46 — honor TG 429 retry_after (single retry).
      # До фикса storm critical DMs (Iter 25 CriticalRecipients × 5 directors
      # после AlertThrottle expire) триггерил 429, остальные DMs молча
      # падали с Error '429'. Теперь — один sleep + retry, дальше raise.
      if res.code == '429' && !retried
        retry_after = (data.dig('parameters', 'retry_after') || res['retry-after']).to_i.clamp(1, 30)
        Rails.logger.warn("[Telegram::Client] 429 on #{method} → sleep #{retry_after}s and retry once")
        sleep(retry_after) if retry_after.positive?
        return api_call(method, body, retried: true)
      end

      raise Error, "Telegram #{method}: #{data['description'] || res.code}" unless data['ok']

      data['result']
    end
  end
end
