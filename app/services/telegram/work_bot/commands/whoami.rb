# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # `/whoami email@victory.ru` — связывание TG-аккаунта с Topnlab-сотрудником.
      #
      # Двухшаговый процесс:
      #   1. Агент пишет `/whoami email@victory.ru`.
      #      Бот ищет email в Topnlab::Client#get_users; если найден — генерит
      #      6-значный код, кладёт в Rails.cache (TTL 15 мин), шлёт письмо.
      #   2. Агент в DM боту присылает только код (6 цифр) — бот сверяет с кэшем
      #      и создаёт/обновляет TelegramUser с topnlab_user_id, email,
      #      first_name, last_name, dm_chat_id.
      #
      # Если агент не сотрудник Topnlab (нет email в /getUsers) — отказ.
      class Whoami < Base
        CODE_TTL = 15.minutes
        CACHE_PREFIX = 'workbot:whoami_code:'

        # Override Base#call — /whoami доступна АНОНИМНЫМ пользователям (это и есть
        # точка входа для регистрации). Иначе catch-22: чтобы зарегистрироваться,
        # нужно быть зарегистрированным.
        def call
          handle
        rescue StandardError => e
          Rails.logger.error("[WorkBot::Command Whoami] #{e.class}: #{e.message}")
          reply("⚠️ Ошибка: #{e.message}")
          :error
        end

        # Public entry: вызывается роутером для команды `/whoami`
        def handle
          if args.blank?
            log_audit('usage', nil)
            return reply(usage)
          end

          email = args.strip.downcase
          unless email.match?(URI::MailTo::EMAIL_REGEXP)
            log_audit('invalid_email', email)
            return reply("⚠️ Не похоже на email: <code>#{escape(email)}</code>")
          end

          topnlab_user = find_topnlab_user(email)
          unless topnlab_user
            log_audit('email_not_in_topnlab', email)
            return reply(
              "🚫 Сотрудник с email <code>#{escape(email)}</code> не найден в Topnlab.\n\n" \
              "Возможные причины:\n" \
              "• email указан с опечаткой\n" \
              "• сотрудник не заведён в CRM\n" \
              "• email в CRM в другом регистре (попробуйте точную копию)\n\n" \
              'Если email верный — обратитесь к руководителю, он зарегистрирует вас командой ' \
              "<code>/whoami_force #{escape(email)}</code>."
            )
          end

          code = format('%06d', SecureRandom.random_number(1_000_000))
          Rails.cache.write(cache_key, {
                              code: code,
                              email: email,
                              topnlab_user_id: topnlab_user['id'],
                              first_name: topnlab_user['firstname'] || topnlab_user['first_name'],
                              last_name: topnlab_user['lastname'] || topnlab_user['last_name'],
                              tg_username: message.dig('from', 'username'),
                              tg_user_id: message.dig('from', 'id')
                            }, expires_in: CODE_TTL)

          TelegramAuthMailer.verification_code(
            email: email,
            code: code,
            tg_username: message.dig('from', 'username').to_s
          ).deliver_later

          log_audit('code_sent', email)
          reply(
            "📧 Код подтверждения отправлен на <code>#{escape(email)}</code>.\n" \
            "Перешлите его боту в личных сообщениях в течение #{(CODE_TTL / 60).to_i} минут."
          )
        end

        # Вызывается отдельно из Router'а когда видит 6 цифр в DM — НЕ команда /whoami,
        # а ответ-кодом. Возвращает true если код принят и TelegramUser создан/обновлён.
        def self.verify_code(message:, code:, client: Telegram::Client.new)
          tg_user_id = message.dig('from', 'id')
          return false if tg_user_id.blank?

          payload = Rails.cache.read(cache_key_for(tg_user_id))
          return false if payload.nil?
          return false unless code.to_s.strip == payload[:code].to_s

          tg_user = TelegramUser.find_or_initialize_by(tg_user_id: tg_user_id)
          tg_user.assign_attributes(
            tg_username: payload[:tg_username] || tg_user.tg_username,
            topnlab_user_id: payload[:topnlab_user_id],
            email: payload[:email],
            first_name: payload[:first_name],
            last_name: payload[:last_name],
            dm_chat_id: message.dig('chat', 'id'),
            status: 'active'
          )
          tg_user.save!

          Rails.cache.delete(cache_key_for(tg_user_id))

          client.send_message(
            "✅ Готово, #{tg_user.display_name}! Аккаунт привязан к Topnlab.",
            chat_id: message.dig('chat', 'id'),
            parse_mode: 'HTML'
          )
          true
        end

        def self.cache_key_for(tg_user_id)
          "#{CACHE_PREFIX}#{tg_user_id}"
        end

        private

        def cache_key
          self.class.cache_key_for(message.dig('from', 'id'))
        end

        def find_topnlab_user(email)
          users = Topnlab::Client.new.get_users
          users.find { |u| u['email'].to_s.downcase == email }
        rescue Topnlab::Client::Error => e
          Rails.logger.error("[Whoami] Topnlab unavailable: #{e.message}")
          log_audit('topnlab_api_error', "#{email} (#{e.message})")
          nil
        end

        def log_audit(result, args)
          return if tg_user.nil? && message.dig('from', 'id').blank?

          BotCommandLog.create!(
            tg_user_id: tg_user&.tg_user_id || message.dig('from', 'id'),
            command: '/whoami',
            args: args.to_s,
            result: result
          )
        rescue StandardError => e
          Rails.logger.warn("[Whoami#log_audit] #{e.class}: #{e.message}")
        end

        def usage
          "Использование: <code>/whoami email@victory.ru</code>\n" \
            "После отправки команды бот пришлёт код подтверждения на указанный email.\n" \
            'Ответьте боту в личных сообщениях этим кодом — аккаунт будет привязан.'
        end

        def escape(s)
          s.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
        end
      end
    end
  end
end
