# frozen_string_literal: true

module Telegram
  module WorkBot
    # Iter 61 — финальный шаг share-flow (фото сотруднику БЕЗ создания задачи).
    #
    # Контекст: PhotoDispositionCallback двинул state на step='share_caption'
    # и зафиксировал target_staff_id в pa['data']. Юзер вводит текст подписи
    # ИЛИ /skip — мы:
    #   1. Парсим caption (nil если /skip / blank)
    #   2. Качаем фото в /tmp + upload в NC (archive, soft-fail)
    #   3. Шлём sendPhoto к target.dm_chat_id с file_id (TG принимает file_id
    #      как `photo` param, без re-upload) + caption включает mention
    #      отправителя + NC archive-link
    #   4. Confirmation директору + clear pending_action
    #
    # Главное отличие от PhotoTaskContinuation — Task НЕ создаётся. Это чистая
    # информационная пересылка. attachments тоже не висит на entity (фото
    # живёт в NC + у получателя в DM, этого достаточно для «глянь»).
    class PhotoShareContinuation
      SKIP_TOKEN = '/skip'
      CAPTION_MAX = 1000 # своя truncate перед TG-shaped caption (TG limit 1024)

      def initialize(msg:, tg_user:, pending_action:, client: ::Telegram::Client.new)
        @msg     = msg
        @tg_user = tg_user
        @pa      = pending_action
        @client  = client
      end

      def call
        text     = @msg['text'].to_s.strip
        file_id  = @pa.dig('data', 'file_id')
        staff_id = @pa.dig('data', 'target_staff_id')

        return reply_and_clear('⚠️ Нет file_id в state — пришли фото заново.', :error) if file_id.blank?
        return reply_and_clear('⚠️ Получатель не выбран — пришли фото заново.', :error) if staff_id.blank?

        staff = ::TelegramUser.find_by(id: staff_id)
        return reply_and_clear('⚠️ Сотрудник не найден.', :error) if staff.nil?

        caption_text = parse_caption(text)
        nc_result    = upload_to_nc(file_id, staff)

        delivered = deliver_photo_to_staff(staff, file_id, caption_text, nc_result)
        @tg_user.clear_pending_action!

        reply_back(success_text(staff, caption_text, nc_result, delivered: delivered))
        :handled
      rescue StandardError => e
        Rails.logger.error("[PhotoShareContinuation] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
        reply_and_clear("⚠️ Внутренняя ошибка: #{e.message.to_s.truncate(120)}", :error)
      end

      private

      # /skip → nil; blank → nil; иначе trim + truncate.
      def parse_caption(text)
        return nil if text.blank?
        return nil if text.casecmp?(SKIP_TOKEN)

        text.truncate(CAPTION_MAX)
      end

      def upload_to_nc(file_id, staff)
        tmp = @client.download_file(file_id, prefix: 'workbot-share-photo')
        return nil if tmp.nil?

        dir_name = staff.tg_username.presence ||
                   staff.display_name.to_s.gsub(/[^[:alnum:]_-]+/, '_').squeeze('_').delete_suffix('_').presence ||
                   "id_#{staff.id}"
        date_dir = Time.current.strftime('%d.%m.%y')
        short    = Digest::SHA1.hexdigest(file_id.to_s)[0, 6]
        remote_path = "Офис/НЕДВИЖИМОСТЬ/ВХОДЯЩИЕ/ПО СОТРУДНИКАМ/#{dir_name}/#{date_dir}/" \
                      "photo-#{Time.current.strftime('%H.%M.%S')}-#{short}.jpg"

        nc = Nextcloud::Client.new
        parent = remote_path.split('/')[0...-1].join('/')
        nc.mkdir_p(parent)
        nc.upload(tmp.path, remote_path)

        Nextcloud::ShareLinkGenerator.for(
          path: remote_path,
          ttl: 30.days,
          created_by: @tg_user
        )
      rescue StandardError => e
        Rails.logger.warn("[PhotoShareContinuation#upload_to_nc] #{e.class}: #{e.message}")
        nil
      ensure
        tmp&.close
        tmp&.unlink
      end

      # Шлёт фото в DM сотрудника. file_id принимается как `photo` параметр
      # Telegram API (server-side resolved, без re-upload).
      # @return [Boolean] true если sendPhoto успешен; false иначе.
      def deliver_photo_to_staff(staff, file_id, caption, nc_result)
        chat_id = staff.dm_chat_id || staff.tg_user_id
        if chat_id.blank?
          Rails.logger.warn("[PhotoShareContinuation] no chat_id для staff=#{staff.id}")
          return false
        end

        cap_lines = ["📷 От #{@tg_user.mention}"]
        cap_lines << escape_html(caption) if caption.present?
        cap_lines << ''
        cap_lines << "<i>Архив (30 дн): #{nc_result.url}</i>" if nc_result&.url.present?
        caption_str = cap_lines.join("\n").truncate(1024)

        @client.send_photo(chat_id, file_id, caption: caption_str, parse_mode: 'HTML')
        true
      rescue ::Telegram::Client::Error, StandardError => e
        Rails.logger.warn("[PhotoShareContinuation#deliver_photo_to_staff] sendPhoto failed: #{e.class}: #{e.message}")
        # Fallback: хотя бы текстовое сообщение с share-link если NC OK.
        deliver_text_fallback(staff, nc_result)
      end

      # Если sendPhoto упал (file_id expired / TG глючит) — слать текст со ссылкой.
      def deliver_text_fallback(staff, nc_result)
        return false if nc_result&.url.blank?

        chat_id = staff.dm_chat_id || staff.tg_user_id
        return false if chat_id.blank?

        text = "📷 От #{@tg_user.mention}\n" \
               "<i>(не удалось переслать фото через TG, см. в облаке)</i>\n" \
               "#{nc_result.url}"
        @client.send_message(text, chat_id: chat_id, parse_mode: 'HTML')
        true
      rescue StandardError
        false
      end

      def success_text(staff, caption, nc_result, delivered:)
        lines = []
        if delivered
          lines << "✅ <b>Переслано</b> #{staff.mention}"
        else
          lines << "⚠️ <b>Не удалось доставить</b> #{staff.mention}"
          lines << '<i>Проверь — она писала боту хоть раз (нужен dm_chat_id)?</i>'
        end
        lines << "Подпись: <i>#{escape_html(caption).truncate(120)}</i>" if caption.present?
        lines << '<i>Без подписи</i>' if caption.blank? && delivered
        if nc_result&.url.present?
          lines << ''
          lines << "Архив (30 дн): #{nc_result.url}"
          lines << "Пароль: <code>#{nc_result.password}</code>" if nc_result.password.present?
        elsif delivered
          lines << ''
          lines << '<i>⚠️ Облако недоступно — архив-копии нет.</i>'
        end
        lines.join("\n")
      end

      def reply_back(text)
        @client.send_message(text,
                             chat_id: @msg.dig('chat', 'id'),
                             reply_to_message_id: @msg['message_id'],
                             parse_mode: 'HTML')
      rescue StandardError => e
        Rails.logger.warn("[PhotoShareContinuation#reply_back] #{e.message}")
      end

      def reply_and_clear(text, status)
        reply_back(text)
        @tg_user.clear_pending_action!
        status
      end

      def escape_html(text)
        text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
      end
    end
  end
end
