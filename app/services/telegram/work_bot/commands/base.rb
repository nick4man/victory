# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # Базовый класс командного хендлера. Подкласс получает разобранную команду
      # и сырое TG message, отвечает текстом обратно в тот же чат/топик.
      #
      # Подкласс должен реализовать #handle(args) и опц. указать:
      #   `manager_only true`  — требует TelegramUser#is_manager (legacy boolean)
      #   `director_only true` — требует role=director|admin (Phase 7.1+ для voice intake)
      class Base
        class << self
          def manager_only(val = true)
            @manager_only = val
          end

          def manager_only?
            @manager_only == true
          end

          def director_only(val = true)
            @director_only = val
          end

          def director_only?
            @director_only == true
          end

          # Phase 7.3 — публичные команды (/help, /start). Не требуют
          # tg_user.present?. Гарантирует пропуск всех role-gates.
          def public_command(val = true)
            @public_command = val
          end

          # BOTTLENECK — команда пишет BotCommandLog сама, со своими полями
          # (Whoami / WhoamiForce). Базовый аудит тогда молчит, иначе на каждый
          # вызов приходится две строки и adoption-метрика двоится.
          def self_audited(val = true)
            @self_audited = val
          end

          def self_audited?
            @self_audited == true
          end

          def public_command?
            @public_command == true
          end
        end

        attr_reader :tg_user, :message, :args, :client

        def initialize(message:, args:, tg_user:, client: Telegram::Client.new)
          @message = message
          @args = args.to_s.strip
          @tg_user = tg_user
          @client = client
        end

        def call
          # Аргументы снимаем ДО dispatch: resolve_lead! выкусывает из @args
          # номер лида, а в аудите нужна именно ссылка на лид (найдено ревью).
          audited_args = @args.to_s
          outcome = dispatch
          audit!(outcome, args: audited_args)
          outcome
        rescue StandardError => e
          Rails.logger.error("[WorkBot::Command #{self.class.name}] #{e.class}: #{e.message}")
          audit!(:error, args: audited_args, error_class: e.class.name, error_message: e.message)
          reply("⚠️ Ошибка: #{e.message}")
          :error
        end

        protected

        def handle
          raise NotImplementedError
        end

        def reply(text, **opts)
          # reply_markup пробрасывается осознанно: команда-дублёр кнопок
          # (/segment без аргумента) присылает ту же клавиатуру, что карточка.
          client.send_message(
            text,
            chat_id: message.dig('chat', 'id'),
            reply_to_message_id: message['message_id'],
            message_thread_id: message['message_thread_id'],
            parse_mode: opts.fetch(:parse_mode, 'HTML'),
            **opts.slice(:reply_markup)
          )
        end

        # Phase 9 Iter 1 — Authorization helper для commands которые операют
        # ОТДЕЛЬНЫЙ lead-event (не обязательно "свой"). Разрешает: assignee
        # лида ИЛИ manager (для override). Используется в /stage, /note.
        # @param lead [LeadEvent]
        def assignee_or_manager?(lead)
          return false if tg_user.nil?
          # Phase 13 Iter 41 — расширили до manager_or_director? (directors/admins
          # тоже могут override). До фикса director без is_manager=true не мог
          # делать /stage/ /note по чужому лиду.
          return true  if tg_user.manager_or_director?
          return false if lead.nil?

          lead.assigned_to_id == tg_user.id
        end

        # Phase 10 Iter 19 — Shared HTML escape helper для безопасной интерполяции
        # user-controlled strings (Inquiry.name, TelegramUser.first_name, и т.п.)
        # в parse_mode=HTML messages. Используется индивидуально в каждом command/
        # callback/service — audit confirmed coverage. Helper централизован для
        # future-proofing.
        def escape_html(text)
          text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
        end

        # Личная переписка (DM) с пользователем-агентом — если у TelegramUser
        # есть dm_chat_id, шлём туда; иначе пытаемся отправить по tg_user_id
        # (Telegram примет, если пользователь когда-либо писал боту).
        def dm(text, to: tg_user, **opts)
          chat_id = to&.dm_chat_id || to&.tg_user_id
          return false if chat_id.blank?

          client.send_message(text, chat_id: chat_id, parse_mode: opts.fetch(:parse_mode, 'HTML'))
        rescue Telegram::Client::Error => e
          Rails.logger.warn("[WorkBot] DM failed for #{to&.mention}: #{e.message}")
          false
        end

        # Phase 15 — Universal LeadEvent resolver для DM/group dual-context.
        # В group: reply-to-anchor (как было исторически).
        # В DM: explicit lead_id как 1-й arg.
        #
        # Если 1-й токен @args — положительное целое, считаем его lead_id и
        # КОНСУМИМ из @args (команда дальше получает остаток без lead_id).
        # Иначе fallback на find_lead_via_reply.
        #
        # @return [LeadEvent, nil] resolved лид или nil
        def resolve_lead!
          parts = @args.to_s.split(/\s+/, 2)
          if (id = Integer(parts[0].to_s, exception: false)) && id.positive?
            @args = parts[1].to_s.strip # consume lead_id, оставляем rest
            return ::LeadEvent.find_by(id: id)
          end
          find_lead_via_reply
        end

        # Reply-to-anchor lookup (legacy way). Возвращает LeadEvent или nil.
        # Использует message['reply_to_message']['message_id'] → LeadEvent.anchor_message_id.
        def find_lead_via_reply
          reply_to = @message['reply_to_message']
          return nil unless reply_to

          ::LeadEvent.find_by(anchor_message_id: reply_to['message_id'])
        end

        # Hint-сообщение «лид не найден» — единый текст для всех команд.
        def lead_not_found_hint(cmd)
          "⚠️ Лид не найден. В group — reply на якорь лида. " \
            "В DM — укажи lead_id первым аргументом: <code>/#{cmd} 87 …</code>"
        end

        private

        # Гейты вынесены из #call, чтобы исход был символом, а не возвратом
        # reply (тот отдаёт хэш ответа Telegram — в result его писать нельзя).
        def dispatch
          return handle if self.class.public_command?

          if tg_user.nil?
            reply('🚫 Команда доступна только сотрудникам АН. Свяжитесь с руководителем.')
            return :denied_not_staff
          end

          # Phase 13 Iter 41 — manager_or_director? включает legacy is_manager +
          # директоров + admin. До фикса /assign блокировался для директора с
          # role=director, is_manager=false.
          if self.class.manager_only? && !tg_user.manager_or_director?
            reply('🚫 Команда доступна только руководителям.')
            return :denied_manager
          end

          if self.class.director_only? && !tg_user.can_voice_distribute?
            reply('🚫 Только для директора АН. Используй /task @username dd.MM.yy <текст> для одиночной задачи.')
            return :denied_director
          end

          handle
        end

        # BOTTLENECK — до этого места текстовые команды не попадали в
        # BotCommandLog вообще: писали только CallbacksRouter, два варианта
        # /whoami и StaffChatResponder, хотя комментарий в модели обещает
        # «unified bot-action stream». Для базовой линии показов это критично:
        # /segment, /stage и /show — ручные отметки, по которым оценивают людей,
        # а BOTTLENECK требует, чтобы ручной ввод был прослеживаем (там же —
        # suspicious_flag на Task). Аудит здесь, а не в каждой команде, чтобы
        # новая команда получала его по факту наследования.
        def audit!(outcome, args:, error_class: nil, error_message: nil)
          return if self.class.self_audited?

          tg_user_id = @message.is_a?(Hash) ? @message.dig('from', 'id') : nil
          return if tg_user_id.blank?

          BotCommandLog.create!(
            tg_user_id:    tg_user_id,
            command:       command_key,
            args:          args.truncate(500),
            result:        outcome.is_a?(Symbol) ? outcome.to_s : 'handled',
            error_class:   error_class,
            error_message: error_message.to_s.presence&.truncate(500)
          )
        rescue StandardError => e
          Rails.logger.warn("[WorkBot::Commands::Base#audit!] #{e.class}: #{e.message}")
        end

        # С ведущим слэшем — как пишет существующий Commands::Whoami#log_audit.
        # Иначе одна и та же команда попадала бы в журнал под двумя ключами и
        # ломала документированную метрику group(:command).count (найдено ревью).
        def command_key
          "/#{self.class.name.to_s.demodulize.underscore}"
        end
      end
    end
  end
end
