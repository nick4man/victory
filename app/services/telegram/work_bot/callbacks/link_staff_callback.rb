# frozen_string_literal: true

module Telegram
  module WorkBot
    module Callbacks
      # Связывание телеграм-аккаунта с учёткой сотрудника — кнопками.
      #
      # Заменяет команду `/link @username email@victory.ru`, которой за всё время
      # пользовались ноль раз. Замер показал общее правило: из 24 команд бота
      # реально вызывались 9, и все текстовые — ни разу. Работают только кнопки в
      # присланных сообщениях, поэтому экран целиком кнопочный.
      #
      #   link_staff              — список телеграм-аккаунтов без связи
      #   link_staff:tg:<tg_id>   — выбран аккаунт, показать кандидатов из CRM
      #   link_staff:do:<tg_id>:<user_id> — связать
      #   link_staff:report       — кому бот не сможет написать и почему
      #
      # Только директор: неверная связь уводит уведомления по чужим объектам к
      # постороннему человеку и остаётся незамеченной.
      class LinkStaffCallback < Base
        director_only

        MAX_BUTTONS = 8

        def handle
          case args[0]
          when nil, 'list' then show_unlinked
          when 'tg'        then show_candidates(args[1])
          when 'do'        then link(args[1], args[2])
          when 'report'    then show_report
          else ack('Неизвестное действие', alert: true)
          end
        end

        private

        def show_unlinked
          unlinked = TelegramUser.where(status: 'active')
                                 .where.missing(:user)
                                 .order(:id)
                                 .limit(MAX_BUTTONS)

          if unlinked.empty?
            reply_in_topic('Все активные телеграм-аккаунты уже связаны с учётками.')
            return ack
          end

          buttons = unlinked.map do |tg|
            [{ text: label_for_tg(tg), callback_data: "link_staff:tg:#{tg.id}" }]
          end
          buttons << [{ text: '🔎 Кому бот не сможет написать', callback_data: 'link_staff:report' }]

          send_with_buttons('Кого связать с учёткой в CRM?', buttons)
          ack
        end

        def show_candidates(tg_id)
          tg = TelegramUser.find_by(id: tg_id)
          return ack('Аккаунт не найден', alert: true) if tg.nil?
          return ack('Этот аккаунт уже связан', alert: true) if tg.user.present?

          candidates = User.where(role: %i[agent admin], active: true, deleted_at: nil)
                           .where(telegram_user_id: nil)
                           .order(:last_name, :email)
                           .limit(MAX_BUTTONS)

          if candidates.empty?
            reply_in_topic('Нет свободных учёток сотрудников — все уже связаны.')
            return ack
          end

          buttons = candidates.map do |u|
            [{ text: label_for_user(u), callback_data: "link_staff:do:#{tg.id}:#{u.id}" }]
          end

          send_with_buttons("С кем связать #{label_for_tg(tg)}?", buttons)
          ack
        end

        def link(tg_id, user_id)
          tg   = TelegramUser.find_by(id: tg_id)
          user = User.find_by(id: user_id)
          return ack('Аккаунт или сотрудник не найден', alert: true) if tg.nil? || user.nil?
          return ack('Этот аккаунт уже связан', alert: true) if tg.user.present?
          return ack('У сотрудника уже есть телеграм', alert: true) if user.telegram_user_id.present?

          user.update_column(:telegram_user_id, tg.id) # rubocop:disable Rails/SkipsModelValidations

          # Сразу говорим, дойдут ли до него сообщения: связь установлена, но
          # личка может быть закрыта — тогда рассылка всё равно не сработает, и
          # узнать об этом лучше сейчас, а не через неделю молчания.
          reason = Crm::TelegramReachability.for(user.reload)
          suffix = reason == :ok ? '' : "\n⚠️ #{Crm::TelegramReachability.explain(reason)}"
          reply_in_topic("✅ #{label_for_tg(tg)} → #{label_for_user(user)}#{suffix}")
          ack('Связано')
        end

        def show_report
          agents = User.where(role: %i[agent admin], active: true, deleted_at: nil)
                       .includes(:telegram_user)
          report = Crm::TelegramReachability.report(agents)

          lines = ["<b>Достижимость сотрудников в Telegram</b>\n"]
          report.each do |reason, users|
            next if users.empty?

            mark = reason == :ok ? '✅' : '⚠️'
            lines << "#{mark} #{Crm::TelegramReachability.explain(reason)} — #{users.size}"
            users.first(MAX_BUTTONS).each { |u| lines << "   • #{label_for_user(u)}" }
          end

          reply_in_topic(lines.join("\n"))
          ack
        end

        def send_with_buttons(text, buttons)
          msg = callback_query['message'] || {}
          client.send_message(
            text,
            chat_id: msg.dig('chat', 'id'),
            message_thread_id: msg['message_thread_id'],
            reply_markup: { inline_keyboard: buttons }
          )
        end

        def label_for_tg(tg)
          name = [tg.first_name, tg.last_name].compact_blank.join(' ')
          handle = tg.tg_username.present? ? "@#{tg.tg_username}" : "id#{tg.tg_user_id}"
          name.present? ? "#{name} (#{handle})" : handle
        end

        def label_for_user(user)
          name = [user.first_name, user.last_name].compact_blank.join(' ')
          name.present? ? "#{name} — #{user.email}" : user.email.to_s
        end
      end
    end
  end
end
