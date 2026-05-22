# frozen_string_literal: true

module Telegram
  module WorkBot
    # Iter 60 — финальный шаг «📤 Сотрудникам с задачей» из photo-disposition.
    #
    # Контекст: PhotoIntakeProcessor сохранил pending_action {file_id, step:
    # 'choose_destination'}. Callback handle_dispose('staff') продвинул в step:
    # 'describe_task'. Здесь юзер ввёл текст вида «@irina проверь паспорт сегодня
    # до 18:00» — мы парсим, создаём Task с attached фото, отправляем DM ассайни.
    #
    # Парсинг — лёгкий regex, не LLM (юзер сам форматирует, и LLM-парс был бы
    # overengineering для 1-line описания). Если регекс не находит @username
    # → отвечаем «укажи @username получателя».
    class PhotoTaskContinuation
      USERNAME_RE = /@([A-Za-z][A-Za-z0-9_]{4,31})/.freeze
      ID_TOKEN_RE = /\bid:(\d+)\b/i.freeze

      def initialize(msg:, tg_user:, pending_action:, client: ::Telegram::Client.new)
        @msg     = msg
        @tg_user = tg_user
        @pa      = pending_action
        @client  = client
      end

      def call
        text = @msg['text'].to_s.strip
        file_id = @pa.dig('data', 'file_id')

        return reply_and_clear('⚠️ Нет file_id в pending state — пришли фото заново.', :error) if file_id.blank?

        assignee_token = extract_assignee_token(text)
        if assignee_token.nil?
          return reply_back('⚠️ Не вижу получателя. Укажи <code>@username</code> или <code>id:N</code> в тексте задачи. Можешь повторить.')
        end

        assignee = ::TelegramUser.resolve_identifier(assignee_token)
        if assignee.nil?
          return reply_back("⚠️ Сотрудник <code>#{escape_html(assignee_token)}</code> не найден. Повтори с корректным username/id.")
        end

        title = strip_addressee(text, assignee_token).presence || text
        nc_result = upload_to_nc(file_id, assignee)

        task = ::Task.create!(
          title: title.truncate(280),
          assignee_id: assignee.id,
          created_by_id: @tg_user.id,
          status: 'open',
          kind: 'document',
          priority: 'normal',
          assigned_at: Time.current
        )
        task.append_attachment!(
          tg_file_id: file_id,
          nc_url: nc_result&.url.to_s,
          kind: 'image',
          uploaded_by: @tg_user.id
        )

        deliver_dm_to_assignee(task, assignee, file_id, nc_result)
        @tg_user.clear_pending_action!

        reply_back(success_text(task, assignee, nc_result))
        :handled
      rescue StandardError => e
        Rails.logger.error("[PhotoTaskContinuation] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
        reply_and_clear("⚠️ Внутренняя ошибка: #{e.message.to_s.truncate(120)}", :error)
      end

      private

      # @username имеет приоритет; если нет — id:N.
      def extract_assignee_token(text)
        if (m = text.match(USERNAME_RE))
          return m[1].downcase
        end
        if (m = text.match(ID_TOKEN_RE))
          return "id:#{m[1]}"
        end
        nil
      end

      def strip_addressee(text, token)
        cleaned = text.dup
        if token.start_with?('id:')
          cleaned.gsub!(ID_TOKEN_RE, '')
        else
          cleaned.gsub!(USERNAME_RE) { |m| m.downcase == "@#{token.downcase}" ? '' : m }
        end
        # убираем двоеточие в начале / двойные пробелы
        cleaned.strip.sub(/\A[:\-—,]\s*/, '').squeeze(' ').strip
      end

      def upload_to_nc(file_id, assignee)
        tmp = @client.download_file(file_id, prefix: 'workbot-task-photo')
        return nil if tmp.nil?

        dir_name = assignee.tg_username.presence || assignee.display_name.to_s.gsub(/[^[:alnum:]_-]+/, '_').squeeze('_').delete_suffix('_').presence || "id_#{assignee.id}"
        date_dir = Time.current.strftime('%d.%m.%y')
        remote_path = "Офис/НЕДВИЖИМОСТЬ/ВХОДЯЩИЕ/ПО СОТРУДНИКАМ/#{dir_name}/#{date_dir}/photo-#{Time.current.strftime('%H.%M.%S')}-#{Digest::SHA1.hexdigest(file_id)[0, 6]}.jpg"

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
        Rails.logger.warn("[PhotoTaskContinuation#upload_to_nc] #{e.class}: #{e.message}")
        nil
      ensure
        tmp&.close
        tmp&.unlink
      end

      def deliver_dm_to_assignee(task, assignee, file_id, nc_result)
        chat_id = assignee.dm_chat_id || assignee.tg_user_id
        return if chat_id.blank?

        caption = "📷 <b>Задача #{task_id_text(task)}</b> от #{@tg_user.mention}\n" \
                  "#{escape_html(task.title)}"
        caption += "\n\nОблако (30 дн): #{nc_result.url}" if nc_result&.url.present?
        caption += "\nПароль: <code>#{nc_result.password}</code>" if nc_result&.password.present?

        # send_photo принимает URL — для file_id используем форму с file_id в payload.
        # У нас Telegram::Client#send_photo предполагает URL; для file_id нужен sendPhoto
        # с photo=<file_id> (TG поддерживает обе формы). Используем send_message + последующий
        # forward невозможен (no source chat id для bot's own photo). Решение — простой
        # caption text с ссылкой на NC (без TG-pre-view); если NC недоступен — без вложения.
        @client.send_message(caption, chat_id: chat_id, parse_mode: 'HTML')
      rescue StandardError => e
        Rails.logger.warn("[PhotoTaskContinuation#deliver_dm_to_assignee] #{e.class}: #{e.message}")
      end

      def task_id_text(task)
        "##{task.id}"
      end

      def success_text(task, assignee, nc_result)
        lines = ["✅ <b>Задача ##{task.id} создана</b> для #{assignee.mention}."]
        lines << "Заголовок: #{escape_html(task.title.to_s.truncate(120))}"
        if nc_result&.url.present?
          lines << "Фото загружено: #{nc_result.url}"
          lines << "Пароль: <code>#{nc_result.password}</code>" if nc_result.password.present?
        else
          lines << '<i>⚠️ Облако недоступно — фото только в TG file_id (не share-link).</i>'
        end
        lines.join("\n")
      end

      def reply_back(text)
        @client.send_message(text,
                             chat_id: @msg.dig('chat', 'id'),
                             reply_to_message_id: @msg['message_id'],
                             parse_mode: 'HTML')
      rescue StandardError => e
        Rails.logger.warn("[PhotoTaskContinuation#reply_back] #{e.message}")
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
