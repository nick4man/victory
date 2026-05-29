# frozen_string_literal: true

module Telegram
  module WorkBot
    module Callbacks
      # Iter 60 — multi-step state-machine для photo disposition в DM.
      # Тригерится PhotoIntakeProcessor (он сохранил pending_action и показал
      # 3-кнопочный prompt). Callback prefix 'photo:' с под-командами:
      #
      #   photo:dispose:cloud   → step #2: спросить целевую папку (general/lead/staff)
      #   photo:dispose:staff   → ждать текстового описания задания (re-route в InboundProcessor)
      #   photo:dispose:cancel  → clear pending_action, "отменено"
      #
      #   photo:target:general                → upload в Inbox/Director/<dd.MM.yy>/, reply share-link
      #   photo:target:lead                   → запрос lead_id (3-й step: list of recent leads)
      #   photo:target:staff                  → запрос username (3-й step: list of active staff)
      #   photo:lead:<lead_event_id>          → upload в /Лиды/<id>/, share-link
      #   photo:staff:<tg_user_id>            → upload в /Сотрудники/<username>/<date>/, share-link
      #
      # Безопасность: manager_only (см. Base) — это директорский oversight flow.
      class PhotoDispositionCallback < Base
        manager_only

        # Где живут загруженные фото в Nextcloud. assert_safe_path! на стороне
        # Client отсекает Sensitive segments (БУХГАЛТЕРИЯ/КРЕДИТЫ/Обмен/ПРИХОДЬКО).
        # Базовый префикс — Офис/НЕДВИЖИМОСТЬ/ВХОДЯЩИЕ — non-sensitive, в реестре
        # nextcloud-cheatsheet.md как Inbox tier.
        BASE_INBOX_DIR = 'Офис/НЕДВИЖИМОСТЬ/ВХОДЯЩИЕ'

        def handle
          subcmd = @args[0].to_s
          rest   = @args[1..] || []

          # Подгружаем pending_action — нужен file_id, и проверяем чтобы
          # state не expired/чужой.
          pa = tg_user.pending_action
          if pa.blank? || pa['type'] != 'photo_disposition'
            return ack('⚠️ Сессия фото истекла. Пришли фото ещё раз.', alert: true)
          end

          case subcmd
          when 'dispose'  then handle_dispose(rest[0].to_s, pa)
          when 'target'   then handle_target_step(rest[0].to_s, pa)
          when 'lead'     then handle_upload_for_lead(rest[0].to_i, pa)
          when 'staff'    then handle_upload_for_staff(rest[0].to_i, pa)
          # Iter 61 — share-flow: переслать фото сотруднику БЕЗ задачи.
          when 'share_to' then handle_share_to(rest[0].to_i, pa)
          else
            ack('⚠️ Неизвестный шаг.', alert: true)
          end
        end

        private

        # =============== Step 1: dispose ===============
        #
        # Iter 60 имел dispose:cloud / dispose:staff / dispose:cancel.
        # Iter 61 ввёл:
        #   cloud   — архив в NC (general/lead; staff target убран как redundant)
        #   share   — переслать сотруднику без задачи (фото + opt caption)
        #   task    — переслать с формальной задачей (renamed from 'staff')
        #   cancel  — отмена (без изменений)
        # 'staff' остаётся alias для 'task' — back-compat для cached
        # callback_data в TG-клиенте (TTL pending_action 10 мин).
        def handle_dispose(action, pa)
          case action
          when 'cloud'  then prompt_choose_cloud_target(pa)
          when 'share'  then prompt_choose_share_staff(pa)
          when 'task'   then prompt_describe_task(pa)
          when 'staff'  then prompt_describe_task(pa) # Iter 60 legacy → task
          when 'cancel' then cancel_pending(pa)
          else ack('⚠️ Неизвестный выбор.', alert: true)
          end
        end

        def prompt_choose_cloud_target(pa)
          tg_user.set_pending_action!(
            type: 'photo_disposition',
            step: 'choose_cloud_target',
            data: pa['data'].to_h
          )

          # Iter 61 — staff sub-option удалён (дублирует новый dispose:share).
          markup = {
            inline_keyboard: [
              [{ text: '📂 Общая папка', callback_data: 'photo:target:general' }],
              [{ text: '🎯 К лиду',       callback_data: 'photo:target:lead' }],
              [{ text: '⬅️ Назад',        callback_data: 'photo:dispose:cancel' }]
            ]
          }
          edit_keyboard_with_text('☁️ Куда сохранить?', markup)
          ack
        end

        # Iter 61 — share-flow Step 2: выбор сотрудника (без создания задачи).
        # После выбора → step=share_caption, ждём opt-caption или /skip.
        def prompt_choose_share_staff(pa)
          tg_user.set_pending_action!(
            type: 'photo_disposition',
            step: 'choose_share_staff',
            data: pa['data'].to_h
          )

          staff = active_staff_for_picker
          if staff.empty?
            return ack_and_text('⚠️ Нет активных сотрудников для пересылки.', alert: true)
          end

          buttons = staff.map do |s|
            [{ text: staff_button_text(s), callback_data: "photo:share_to:#{s.id}" }]
          end
          buttons << [{ text: '⬅️ Назад', callback_data: 'photo:dispose:cancel' }]

          edit_keyboard_with_text(
            '📤 Кому переслать фото (без создания задачи)?',
            { inline_keyboard: buttons }
          )
          ack
        end

        def prompt_describe_task(pa)
          tg_user.set_pending_action!(
            type: 'photo_disposition',
            step: 'describe_task',
            data: pa['data'].to_h
          )

          edit_keyboard_with_text(
            "📝 Опиши задание и укажи получателя:\n" \
            "Например: <code>@irina проверь паспорт клиента сегодня до 18:00</code>\n\n" \
            'Отправь обычным текстовым сообщением — фото будет приложено к задаче.',
            { inline_keyboard: [[{ text: '⬅️ Отмена', callback_data: 'photo:dispose:cancel' }]] }
          )
          ack
        end

        # =============== Iter 61 share-flow Step 3: target selected ===============
        #
        # Director выбрал сотрудника из picker'а (callback_data: photo:share_to:<id>).
        # Сохраняем target_staff_id в pending_action.data + step=share_caption,
        # просим опциональную подпись или /skip.
        def handle_share_to(staff_id, pa)
          target = ::TelegramUser.find_by(id: staff_id)
          return ack('⚠️ Сотрудник не найден.', alert: true) if target.nil?

          tg_user.set_pending_action!(
            type: 'photo_disposition',
            step: 'share_caption',
            data: pa['data'].to_h.merge('target_staff_id' => staff_id)
          )

          edit_keyboard_with_text(
            "📤 Получатель: <b>#{target.mention}</b>\n\n" \
            "Опционально добавь подпись (контекст для сотрудника) или жми <code>/skip</code>.\n" \
            "Например: <i>«глянь, такого вида паспорт не принимаем»</i>.\n\n" \
            'Отправь следующим сообщением.',
            { inline_keyboard: [[{ text: '⬅️ Отмена', callback_data: 'photo:dispose:cancel' }]] }
          )
          ack
        end

        def cancel_pending(_pa)
          tg_user.clear_pending_action!
          edit_keyboard_with_text('✖️ Отменено. Фото не сохранено.', nil)
          ack('Отменено')
        end

        # =============== Step 2: target:general|lead|staff ===============

        def handle_target_step(target_kind, pa)
          case target_kind
          when 'general' then upload_to_general(pa)
          when 'lead'    then prompt_choose_lead(pa)
          when 'staff'   then prompt_choose_staff(pa)
          else ack('⚠️ Неизвестная цель.', alert: true)
          end
        end

        def upload_to_general(pa)
          file_id = pa.dig('data', 'file_id')
          return ack('⚠️ Нет file_id.', alert: true) if file_id.blank?

          date_dir = Time.current.strftime('%d.%m.%y')
          remote_path = "#{BASE_INBOX_DIR}/#{date_dir}/#{filename_for(file_id)}"

          result = upload_with_share(file_id: file_id, remote_path: remote_path)
          return ack('⚠️ Облако недоступно, попробуй позже.', alert: true) if result.nil?

          tg_user.clear_pending_action!
          edit_keyboard_with_text(success_text_general(remote_path, result), nil)
          ack('✅ Загружено')
        end

        def prompt_choose_lead(pa)
          tg_user.set_pending_action!(
            type: 'photo_disposition',
            step: 'choose_lead',
            data: pa['data'].to_h
          )

          leads = recent_leads_for_picker
          if leads.empty?
            return ack_and_text('⚠️ Нет недавних лидов. Используй «Общую папку» или /lead создай вручную.', alert: true)
          end

          buttons = leads.map do |le|
            [{ text: lead_button_text(le), callback_data: "photo:lead:#{le.id}" }]
          end
          buttons << [{ text: '⬅️ Назад', callback_data: 'photo:dispose:cloud' }]

          edit_keyboard_with_text('🎯 Выбери лид:', { inline_keyboard: buttons })
          ack
        end

        def prompt_choose_staff(pa)
          tg_user.set_pending_action!(
            type: 'photo_disposition',
            step: 'choose_staff',
            data: pa['data'].to_h
          )

          staff = active_staff_for_picker
          if staff.empty?
            return ack_and_text('⚠️ Нет активных сотрудников.', alert: true)
          end

          buttons = staff.map do |s|
            [{ text: staff_button_text(s), callback_data: "photo:staff:#{s.id}" }]
          end
          buttons << [{ text: '⬅️ Назад', callback_data: 'photo:dispose:cloud' }]

          edit_keyboard_with_text('👤 Выбери сотрудника:', { inline_keyboard: buttons })
          ack
        end

        # =============== Step 3: upload by target ===============

        def handle_upload_for_lead(lead_id, pa)
          file_id = pa.dig('data', 'file_id')
          return ack('⚠️ Нет file_id.', alert: true) if file_id.blank?

          le = LeadEvent.find_by(id: lead_id)
          return ack('⚠️ Лид не найден.', alert: true) if le.nil?

          remote_path = "#{BASE_INBOX_DIR}/ПО ЛИДАМ/#{le.id}/#{filename_for(file_id)}"
          result = upload_with_share(file_id: file_id, remote_path: remote_path)
          return ack('⚠️ Облако недоступно.', alert: true) if result.nil?

          # Phase 12 Iter 39 — note в metadata['notes'] о приложенном фото.
          # Manager увидит в lead-карточке next time, лид-history audit-able.
          append_lead_note(le, result)

          tg_user.clear_pending_action!
          edit_keyboard_with_text(success_text_lead(le, remote_path, result), nil)
          ack('✅ Загружено в лид')
        end

        def handle_upload_for_staff(staff_id, pa)
          file_id = pa.dig('data', 'file_id')
          return ack('⚠️ Нет file_id.', alert: true) if file_id.blank?

          target = TelegramUser.find_by(id: staff_id)
          return ack('⚠️ Сотрудник не найден.', alert: true) if target.nil?

          dir_name = staff_dir_name(target)
          date_dir = Time.current.strftime('%d.%m.%y')
          remote_path = "#{BASE_INBOX_DIR}/ПО СОТРУДНИКАМ/#{dir_name}/#{date_dir}/#{filename_for(file_id)}"
          result = upload_with_share(file_id: file_id, remote_path: remote_path)
          return ack('⚠️ Облако недоступно.', alert: true) if result.nil?

          # DM сотруднику — пробрасываем то же фото (TG file_id живёт долго).
          notify_staff_about_photo(target, result)

          tg_user.clear_pending_action!
          edit_keyboard_with_text(success_text_staff(target, remote_path, result), nil)
          ack('✅ Загружено и отправлено')
        end

        # =============== Helpers — upload, file naming, NC ===============

        # Скачивает TG file → загружает в NC → создаёт share-link.
        # @return [Nextcloud::ShareLinkGenerator::Result, nil] nil при ошибке
        def upload_with_share(file_id:, remote_path:)
          tmp = client.download_file(file_id, prefix: 'workbot-photo')
          return nil if tmp.nil?

          nc = Nextcloud::Client.new
          parent = remote_path.split('/')[0...-1].join('/')
          nc.mkdir_p(parent)
          nc.upload(tmp.path, remote_path)

          Nextcloud::ShareLinkGenerator.for(
            path: remote_path,
            ttl: 30.days,
            created_by: tg_user
          )
        rescue StandardError => e
          Rails.logger.warn("[PhotoDispositionCallback#upload_with_share] #{e.class}: #{e.message}")
          nil
        ensure
          tmp&.close
          tmp&.unlink
        end

        # Имя файла: photo-<dd.MM.yy>-<HH.MM.SS>-<short_hash>.jpg
        # short_hash из file_id чтобы избежать collision на duplicate uploads.
        def filename_for(file_id)
          ts = Time.current.strftime('%d.%m.%y-%H.%M.%S')
          short = Digest::SHA1.hexdigest(file_id.to_s)[0, 6]
          "photo-#{ts}-#{short}.jpg"
        end

        # /ПО СОТРУДНИКАМ/<сегмент> — username если есть, иначе display_name slug.
        def staff_dir_name(target)
          if target.tg_username.present?
            target.tg_username
          else
            target.display_name.to_s.gsub(/[^[:alnum:]_-]+/, '_').squeeze('_').delete_suffix('_').presence || "id_#{target.id}"
          end
        end

        def recent_leads_for_picker
          LeadEvent.open.order(updated_at: :desc).limit(5).to_a
        end

        def lead_button_text(le)
          stage = le.current_stage.to_s.tr('_', ' ')
          updated = le.updated_at.strftime('%d.%m.%y')
          "Лид ##{le.id} • #{stage} • #{updated}"
        end

        def active_staff_for_picker
          ::TelegramUser.assignable.where.not(id: tg_user.id).order(:first_name, :id).limit(10).to_a
        end

        def staff_button_text(s)
          mention = s.tg_username.present? ? "@#{s.tg_username}" : "id:#{s.id}"
          "#{s.display_name} (#{mention})"
        end

        def append_lead_note(le, result)
          entry = {
            'at' => Time.current.iso8601,
            'by' => tg_user.mention,
            'text' => "📷 Прикреплено фото: #{result.url}",
            'kind' => 'photo_attachment'
          }
          le.update!(metadata: le.metadata.merge('notes' => le.append_history(key: 'notes', entry: entry)))
        rescue StandardError => e
          Rails.logger.warn("[PhotoDispositionCallback#append_lead_note] #{e.class}: #{e.message}")
        end

        def notify_staff_about_photo(target, result)
          chat_id = target.dm_chat_id || target.tg_user_id
          return if chat_id.blank?

          text = "📷 <b>Документ от #{tg_user.mention}</b>\n" \
                 "Ссылка: #{result.url}\n" \
                 "Пароль: <code>#{result.password}</code>\n\n" \
                 '<i>Перепост сделан вручную — это не задача, просто файл для ознакомления.</i>'
          client.send_message(text, chat_id: chat_id, parse_mode: 'HTML')
        rescue StandardError => e
          Rails.logger.warn("[PhotoDispositionCallback#notify_staff_about_photo] #{e.class}: #{e.message}")
        end

        # =============== UI: edits & success text =================

        def edit_keyboard_with_text(new_text, markup)
          chat_id = callback_query.dig('message', 'chat', 'id')
          message_id = callback_query.dig('message', 'message_id')
          return if chat_id.blank? || message_id.blank?

          client.edit_message_text(
            new_text,
            chat_id: chat_id,
            message_id: message_id,
            reply_markup: markup,
            parse_mode: 'HTML'
          )
        rescue ::Telegram::Client::Error => e
          Rails.logger.warn("[PhotoDispositionCallback#edit] #{e.message}")
        end

        def ack_and_text(text, alert: false)
          edit_keyboard_with_text(text, nil)
          ack(text, alert: alert)
        end

        def success_text_general(remote_path, result)
          "✅ <b>Загружено в облако</b>\n" \
            "Путь: <code>#{escape_html(remote_path)}</code>\n" \
            "Ссылка (30 дн): #{result.url}\n" \
            "Пароль: <code>#{result.password}</code>"
        end

        def success_text_lead(le, remote_path, result)
          "✅ <b>Загружено в лид ##{le.id}</b>\n" \
            "Путь: <code>#{escape_html(remote_path)}</code>\n" \
            "Ссылка (30 дн): #{result.url}\n" \
            "Пароль: <code>#{result.password}</code>\n" \
            "Заметка в metadata лида создана."
        end

        def success_text_staff(target, remote_path, result)
          "✅ <b>Загружено для #{target.mention}</b>\n" \
            "Путь: <code>#{escape_html(remote_path)}</code>\n" \
            "Ссылка (30 дн): #{result.url}\n" \
            "Пароль: <code>#{result.password}</code>\n" \
            "Сотруднику отправлен DM со ссылкой."
        end

        def escape_html(text)
          text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
        end
      end
    end
  end
end
