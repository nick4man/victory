# frozen_string_literal: true

module Telegram
  module WorkBot
    # Iter 60 — обработка фото в DM от manager+ ролей. Аналог
    # ClientBot::PhotoIntakeProcessor (client-side OCR pipeline), но для
    # внутреннего oversight workflow.
    #
    # Когда директор/менеджер фотографирует документ и отправляет боту в DM —
    # бот спрашивает inline-кнопками, что с фото сделать:
    #   • ☁️ В облако — upload в Nextcloud, share-link клиенту/себе.
    #   • 📤 Сотрудникам — создать Task с фото в attachments + DM ассайни.
    #   • ❌ Отмена
    #
    # State persisted в TelegramUser.dm_pending_action (jsonb, 10-min TTL):
    #   { type: 'photo_disposition', step: 'choose_destination', data: { file_id } }
    #
    # Callback handler (PhotoDispositionCallback) дальше двигает по step'ам.
    # Если TTL истёк — следующее сообщение в DM очистит state (pending_action
    # самостоятельно return'нёт nil + clear).
    class PhotoIntakeProcessor
      # @return [Boolean] true если photo в DM от manager+ (agent — skip,
      #   пусть просто проигнорируется или попадёт в client-photo intake).
      def self.applies?(msg, tg_user = nil)
        return false unless msg.is_a?(Hash)
        return false unless msg['photo'].is_a?(Array) && msg['photo'].any?
        return false unless msg.dig('chat', 'type') == 'private'

        from_id = msg.dig('from', 'id')
        return false if from_id.blank? || msg.dig('from', 'is_bot')

        tg_user ||= ::TelegramUser.find_by(tg_user_id: from_id)
        return false unless tg_user
        return false unless tg_user.status == 'active'
        return false unless tg_user.manager_or_director?

        true
      end

      def self.call(msg, client: ::Telegram::Client.new)
        new(msg, client: client).call
      end

      def initialize(msg, client: ::Telegram::Client.new)
        @msg    = msg
        @client = client
      end

      # @return [Symbol] :awaiting_disposition | :refused | :error
      def call
        from_id = @msg.dig('from', 'id')
        tg_user = ::TelegramUser.find_by(tg_user_id: from_id)
        return :refused if tg_user.nil?

        file_id = largest_photo_file_id
        return reply_and_return('⚠️ Не вижу file_id в payload.', :error) if file_id.blank?

        tg_user.set_pending_action!(
          type: 'photo_disposition',
          step: 'choose_destination',
          data: {
            file_id: file_id,
            received_at: Time.current.iso8601,
            caption: @msg['caption'].to_s.presence
          },
          ttl: 10.minutes
        )

        @client.send_message(
          prompt_text(tg_user),
          chat_id: @msg.dig('chat', 'id'),
          reply_to_message_id: @msg['message_id'],
          parse_mode: 'HTML',
          reply_markup: keyboard_choose_destination
        )
        Rails.logger.info("[WorkBot::PhotoIntakeProcessor] tg_user=#{tg_user.id} file_id=#{file_id} awaiting disposition")
        :awaiting_disposition
      rescue StandardError => e
        Rails.logger.error("[WorkBot::PhotoIntakeProcessor] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
        reply_and_return("⚠️ Внутренняя ошибка: #{e.message.to_s.truncate(120)}", :error)
      end

      private

      # TG присылает фото массивом размеров, последний — самый большой.
      def largest_photo_file_id
        Array(@msg['photo']).last&.dig('file_id')
      end

      def prompt_text(tg_user)
        caption_hint = @msg['caption'].to_s.strip
        lines = ["📷 <b>Фото получено</b>, #{tg_user.mention}."]
        lines << "<i>Подпись:</i> #{escape_html(caption_hint).truncate(200)}" if caption_hint.present?
        lines << ''
        lines << 'Что с ним сделать?'
        lines.join("\n")
      end

      def keyboard_choose_destination
        # Iter 61 — три top-level пути:
        #   • cloud  — архив в Nextcloud (общая папка или папка лида)
        #   • share  — переслать сотруднику БЕЗ задачи (фото в DM + caption)
        #   • task   — переслать с формальной задачей (создаётся Task запись)
        # Iter 60 имел путь 'staff' который значил «with task»; переименовали
        # в 'task' для ясности. Legacy 'staff' остаётся как alias (back-compat).
        {
          inline_keyboard: [
            [
              { text: '☁️ В облако',     callback_data: 'photo:dispose:cloud' },
              { text: '📤 Сотруднику',   callback_data: 'photo:dispose:share' }
            ],
            [
              { text: '✅ С задачей',    callback_data: 'photo:dispose:task' }
            ],
            [
              { text: '❌ Отмена',       callback_data: 'photo:dispose:cancel' }
            ]
          ]
        }
      end

      def reply_and_return(text, status)
        @client.send_message(text,
                             chat_id: @msg.dig('chat', 'id'),
                             reply_to_message_id: @msg['message_id'],
                             parse_mode: 'HTML')
        status
      rescue StandardError
        status
      end

      def escape_html(text)
        text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
      end
    end
  end
end
