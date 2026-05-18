# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # `/help` — список доступных команд бота, отфильтрованный по роли
      # пользователя. Доступен всем (включая незарегистрированных — они
      # увидят только публичные команды).
      class Help < Base
        public_command

        # Каталог команд: [command, level, description].
        # level: :public / :staff / :manager / :director.
        # Порядок в массиве = порядок в выводе.
        ENTRIES = [
          # Public — доступны всем
          ['/help',         :public,   'Этот список команд'],
          ['/whoami',       :public,   'Привязать TG к email сотрудника АН: <code>/whoami email@victory.ru</code>'],
          ['/start',        :public,   'Регистрация: бот запоминает DM-чат для нотификаций'],

          # Staff — для зарегистрированных активных
          ['/done',         :staff,
           'Отметить задачу выполненной: <code>/done 42</code> (или жми кнопку / ✅ реакцию на DM-карточку)'],
          ['/cancel',       :staff,
           'Отменить задачу: <code>/cancel 42 причина</code> (assignee или manager)'],
          ['/reopen',       :staff,
           'Переоткрыть done/canceled задачу (окно 24ч): <code>/reopen 42</code>'],

          # Manager — нужен is_manager=true
          ['/promote',      :manager,  'Активировать сотрудника: <code>/promote @username [manager]</code>'],
          ['/demote',       :manager,  'Снять manager-привилегии: <code>/demote @username</code> (role→agent)'],
          ['/link',         :manager,  'Связать TG-юзера с Topnlab: <code>/link @username email@victory.ru</code>'],
          ['/whoami_force', :manager,  'Зарегистрировать без email-кода (если SMTP недоступен)'],
          ['/lead',         :manager,  'Создать лид вручную: <code>/lead +7900XXX Имя, бюджет N</code>'],
          ['/route',        :manager,
           'Маршрутизировать лид в спец-топик (reply на якорь): <code>/route apartments</code>'],
          ['/assign',       :manager,  'Назначить агента (reply на якорь): <code>/assign @username</code>'],
          ['/stage',        :manager,  'Сменить стадию лида: <code>/stage показ</code>'],
          ['/note',         :manager,  'Заметка в CRM по лиду (reply на якорь): <code>/note текст</code>'],
          ['/task',         :manager,  'Одиночная задача: <code>/task dd.MM.yy текст</code>'],
          ['/close',        :manager,
           'Закрыть лид: <code>/close выиграно</code> или <code>/close проиграно причина:цена</code>'],
          ['/reassign',     :manager,
           'Передать задачу другому: <code>/reassign 42 @username</code> (DM обоим — старому и новому)'],
          ['/deactivate',   :manager,
           'Offboarding сотрудника: <code>/deactivate @username</code> (diagnosis) → <code>… confirm</code> (apply)'],
          ['/learn_topic',  :manager, 'Привязать thread_id к ключу топика: <code>/learn_topic apartments</code>'],

          # Director (Phase 7.2+) — для voice-distribution
          ['🎙 Voice DM', :director, 'Запиши голосовое в DM боту — бот распарсит и предложит подтвердить пакет задач'],
          ['/resume_batch', :director,
           'Переоткрыть expired/cancelled пакет: <code>/resume_batch 42</code> (окно 24ч)']
        ].freeze

        def handle
          lines = ['<b>📖 Команды Виктори-бота</b>', '']

          append_section(lines, 'Всем:', :public)
          append_section(lines, 'Сотрудникам АН:', :staff) if staff?
          append_section(lines, 'Руководителям:', :manager) if manager?
          append_section(lines, 'Директору АН:', :director) if director?

          unless tg_user
            lines << '<i>💡 Сейчас ты не привязан как сотрудник АН. Часть команд скрыта.</i>'
            lines << '<i>Для привязки: <code>/whoami email@victory.ru</code></i>'
          end

          # Phase 12 Iter 36 — в групповых чатах /help spamит общий поток.
          # Шлём один-line redirect inline + полный список приватно в DM.
          # В DM-чате — inline как раньше.
          full_text = lines.join("\n")
          if group_chat?
            send_full_via_dm(full_text)
            reply('📖 Полный список команд отправил тебе в DM боту.')
          else
            reply(full_text)
          end
        end

        private

        def append_section(lines, header, level)
          entries = entries_for(level)
          return if entries.empty?

          lines << "<b>#{header}</b>"
          entries.each { |c, _, d| lines << "  <code>#{c}</code> — #{d}" }
          lines << ''
        end

        def entries_for(level)
          ENTRIES.select { |_, lvl, _| lvl == level }
        end

        def staff?
          return false if tg_user.nil?

          tg_user.status == 'active' || tg_user.is_manager? || tg_user.can_voice_distribute?
        end

        def manager?
          tg_user&.is_manager? || tg_user&.can_voice_distribute?
        end

        def director?
          tg_user&.can_voice_distribute?
        end

        # Phase 12 Iter 36 — distinguish group vs DM. /help в группе → noise
        # для всех, DM-route чище для индивидуальной справки.
        def group_chat?
          chat_type = message.dig('chat', 'type')
          ['group', 'supergroup'].include?(chat_type)
        end

        def send_full_via_dm(text)
          return if tg_user.nil? # незарегистрированный — fallback inline (Base#reply ниже)

          chat_id = tg_user.dm_chat_id || tg_user.tg_user_id
          return if chat_id.blank?

          client.send_message(text, chat_id: chat_id, parse_mode: 'HTML')
        rescue Telegram::Client::Error => e
          # DM не доставлен (бот заблокирован / нет /start) — мягко fallback'имся
          # на inline-reply в группу (лучше шум чем нет ответа).
          Rails.logger.warn("[Help#send_full_via_dm] #{e.message}")
          client.send_message(text,
                              chat_id: message.dig('chat', 'id'),
                              message_thread_id: message['message_thread_id'],
                              reply_to_message_id: message['message_id'],
                              parse_mode: 'HTML')
        end
      end
    end
  end
end
