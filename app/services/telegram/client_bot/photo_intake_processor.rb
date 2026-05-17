# frozen_string_literal: true

module Telegram
  module ClientBot
    # Processes inbound photo messages in personal (DM) chats from clients.
    #
    # Called from Telegram::InboundProcessor when:
    #   - msg contains 'photo' array (Telegram sends photo as array of sizes)
    #   - chat.type == 'private' (DM, not group)
    #
    # Flow:
    #   1. Resolve or stub uploader User (by tg_chat_id)
    #   2. Get largest photo file_id (Telegram orders sizes ascending)
    #   3. Classify document kind via DocumentIntake::PhotoClassifier
    #   4. ClientDocument.intake! → status :received
    #   5. Enqueue DocumentIntake::ParserJob
    #   6. Reply to client: «Спасибо, получили...»
    #
    # Error handling: soft-fail — любая ошибка логируется, клиент получает
    # нейтральный ответ. TG flow не блокируется.
    #
    # Note on authentication: Phase 1 creates a stub User if none found.
    # Phase 2 should wire proper client registration + TelegramUser linkage.
    class PhotoIntakeProcessor
      THANK_YOU_MSG = <<~HTML.strip.freeze
        Спасибо, документ получен! Мы проверим его в течение рабочего дня и пришлём подтверждение.

        Если фото получилось нечётким — отправьте повторно.
      HTML

      ERROR_MSG = <<~HTML.strip.freeze
        К сожалению, не удалось обработать фото. Попробуйте отправить ещё раз или свяжитесь с агентом.
      HTML

      # @param msg [Hash] Telegram message object (already parsed JSON)
      def self.call(msg)
        new(msg).call
      end

      def initialize(msg)
        @msg     = msg
        @tg_chat_id = msg.dig('chat', 'id').to_s
        @tg_msg_id  = msg['message_id'].to_s
        @tg_client  = Telegram::Client.new
      end

      # @return [Symbol] :handled | :error
      def call
        uploader = resolve_uploader
        file_id  = largest_photo_file_id

        unless file_id.present?
          Rails.logger.warn("[ClientBot::PhotoIntakeProcessor] no photo file_id in msg chat=#{@tg_chat_id}")
          return :ignored
        end

        kind = classify_document(file_id)

        doc = ClientDocument.intake!(
          uploader:      uploader,
          kind:          kind,
          tg_chat_id:    @tg_chat_id,
          tg_message_id: @tg_msg_id,
          tg_file_id:    file_id
        )

        DocumentIntake::ParserJob.perform_later(doc.id)

        @tg_client.send_message(THANK_YOU_MSG, chat_id: @tg_chat_id)

        Rails.logger.info(
          "[ClientBot::PhotoIntakeProcessor] doc ##{doc.id} kind=#{kind} " \
          "user_id=#{uploader.id} chat=#{@tg_chat_id}"
        )
        :handled
      rescue StandardError => e
        Rails.logger.error("[ClientBot::PhotoIntakeProcessor] #{e.class}: #{e.message}")
        safe_reply_error
        :error
      end

      private

      # Resolve User by tg_chat_id → TelegramUser linkage (Phase 1: best-effort)
      #
      # Lookup chain:
      #   1. TelegramUser with matching tg_user_id → user association
      #   2. Stub User with placeholder email (для Phase 1 handing-off to full KYC)
      def resolve_uploader
        from_id   = @msg.dig('from', 'id').to_i
        username  = @msg.dig('from', 'username').to_s
        first_nm  = @msg.dig('from', 'first_name').to_s
        last_nm   = @msg.dig('from', 'last_name').to_s

        # TelegramUser → User link (staff often has this; clients may not yet)
        if (tu = TelegramUser.find_by(tg_user_id: from_id))
          return tu.user if tu.respond_to?(:user) && tu.user.present?
        end

        # Fallback — find or create stub client User. Must satisfy User
        # validations: password (Devise schema) + first_name + last_name
        # presence. Password is random urlsafe — never used (Devise off,
        # auth через magic-link/OAuth).
        stub_email = "tg_#{from_id}@clients.victory62.org"
        User.find_or_create_by!(email: stub_email) do |u|
          u.password   = SecureRandom.urlsafe_base64(32)
          u.first_name = first_nm.presence || "TG#{from_id}"
          u.last_name  = last_nm.presence || 'Клиент'
          u.role       = :client
          u.active     = true
          u.crm_status = 'active'
        end
      rescue StandardError => e
        Rails.logger.warn("[ClientBot::PhotoIntakeProcessor#resolve_uploader] #{e.class}: #{e.message}")
        User.first  # last resort — никогда не падаем из-за user resolution
      end

      # Telegram returns photo as array of sizes, largest = last element
      def largest_photo_file_id
        photos = @msg['photo']
        return nil unless photos.is_a?(Array) && photos.any?

        photos.last['file_id']
      end

      # Classify using YandexVision via DocumentIntake::PhotoClassifier.
      # If Yandex Vision is unavailable → :other (ParserJob will handle gracefully)
      def classify_document(file_id)
        image_bytes = fetch_image_bytes(file_id)
        return :other unless image_bytes

        DocumentIntake::PhotoClassifier.call(image_bytes)
      rescue StandardError => e
        Rails.logger.warn("[ClientBot::PhotoIntakeProcessor#classify] #{e.class}: #{e.message}")
        :other
      end

      def fetch_image_bytes(file_id)
        tmp = @tg_client.download_file(file_id, prefix: 'client-intake')
        return nil if tmp.nil?

        tmp.read
      ensure
        tmp&.close
        tmp&.unlink
      end

      def safe_reply_error
        @tg_client.send_message(ERROR_MSG, chat_id: @tg_chat_id)
      rescue StandardError
        # Если даже error reply не ушёл — молча игнорируем
      end
    end
  end
end
