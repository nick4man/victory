# frozen_string_literal: true

module Telegram
  # Parses an inbound Telegram webhook update. The two paths we care about:
  #
  # 1. Reply-to-bot:
  #    Staff member long-presses one of our escalation messages and replies.
  #    update.message.reply_to_message.message_id matches Conversation.telegram_message_id
  #    → save ChatMessage(role: :agent), broadcast to widget.
  #
  # 2. Slash commands inside a conversation thread:
  #    /close, /assign — operate on the matched conversation.
  #
  # Anything else is logged and ignored (silent ack so Telegram doesn't retry).
  class InboundProcessor
    def initialize(payload)
      @update = if payload.is_a?(Hash)
                  payload
                else
                  begin
                    JSON.parse(payload.to_s)
                  rescue StandardError
                    {}
                  end
                end
    end

    def call
      # Phase 9 Iter 8 — Webhook dedup на update_id. Telegram retries на
      # HTTP 5xx, без guard'а один update обработался бы дважды. RecordNotUnique
      # → :duplicate без side-effects.
      return :duplicate if duplicate_update?

      # Phase 2 — callback_query от inline-кнопок маршрутизации/назначения/спама.
      # Должен сработать ДО разбора message — это отдельный тип апдейта без message.
      if (cb = @update['callback_query'])
        return Telegram::WorkBot::CallbacksRouter.new(cb).call
      end

      # Phase 3 — реакции 👍/🔥/✅ на якорь = «принято в работу» (комплементарный
      # сигнал для SLA-watchdog наравне с note в CRM). Требует расширенного
      # allowed_updates через `bin/rails telegram:webhook:setup`.
      if (rx = @update['message_reaction'])
        return Telegram::ReactionHandler.new(rx).call
      end

      msg = @update['message'] || @update['edited_message']
      return :ignored unless msg

      # Phase 7.3+ — touch TG meta (tg_username/dm_chat_id/last_seen_at) для
      # known TelegramUser. Особенно важно: dm_chat_id записывается при первом
      # DM от уже-зарегистрированного юзера (например, Надежда заведена через
      # /link до того как написала боту). Без этого TaskDispatcher не сможет
      # инициировать DM (TG требует «user first contacted bot»).
      touch_known_user_meta(msg)

      # #413 — client TG linking deep-link (`/start <token>`).
      # Должен сработать ДО любых других ClientBot processors (intent classifier
      # не должен видеть служебный токен — это утечка PII в LLM логи и
      # бессмысленный classification).
      if Telegram::ClientBot::LinkProcessor.applies?(msg)
        return Telegram::ClientBot::LinkProcessor.call(msg)
      end

      # #413f — inbound activation flow (bare /start ИЛИ contact-share).
      # Должен идти ПОСЛЕ LinkProcessor (он handle'ит /start с token) и ДО
      # photo/text intake (служебный flow, не контент клиента).
      if Telegram::ClientBot::ActivationRequestProcessor.applies?(msg)
        return Telegram::ClientBot::ActivationRequestProcessor.call(msg)
      end

      # Сбор собственника: сотрудник нажал «Прислать контакт» под запросом по
      # объекту и теперь присылает карточку контакта или текст. Проверяем рано —
      # состояние pending_action делает срабатывание точечным, а без перехвата
      # контакт ушёл бы в client-intake или в LLM-Q&A как обычное сообщение.
      if Telegram::WorkBot::OwnerIntakeProcessor.applies?(msg)
        return Telegram::WorkBot::OwnerIntakeProcessor.call(msg)
      end

      # Iter 60 — manager+ photo в DM → WorkBot photo disposition flow.
      # Должен проверяться РАНЬШЕ client_photo_intake (это перехватывает
      # только staff с manager_or_director?, agents падают дальше в client path).
      if Telegram::WorkBot::PhotoIntakeProcessor.applies?(msg)
        return Telegram::WorkBot::PhotoIntakeProcessor.call(msg)
      end

      # Iter 60 — text-continuation после «📤 Сотрудникам с задачей» в photo
      # flow. Сотрудник нажал кнопку → бот попросил описать задание →
      # сотрудник пишет текстовое сообщение. Перехватываем ДО client text intake
      # и DmQnaHandler, иначе текст уйдёт в LLM-Q&A как обычный вопрос.
      if (rt = workbot_photo_text_continuation(msg))
        return rt
      end

      # A6 Phase 1 — client photo intake (DM + photo array).
      # Клиент фотографирует паспорт/ИНН/ЕГРН в личке — направляем в pipeline.
      # Проверяем ДО WorkBot flow: клиентские DM не должны попадать в staff-bot логику.
      if client_photo_intake?(msg)
        return Telegram::ClientBot::PhotoIntakeProcessor.call(msg)
      end

      # Phase 4D — client TEXT intake в DM. Срабатывает только если non-staff
      # пишет в private chat. Spam/abuse → silently dropped + counter. Inquiry
      # intent → Lead::Intake::TgDmSource → anchor в #ДИСПЕТЧЕРСКОЙ + reply
      # клиенту. См. ClientBot::TextIntakeProcessor.applies?
      if Telegram::ClientBot::TextIntakeProcessor.applies?(msg)
        return Telegram::ClientBot::TextIntakeProcessor.call(msg)
      end

      # Phase 7.2 — voice от директора АН в DM боту → Voice → LLM extract →
      # TaskBatch + preview с inline-кнопками подтверждения. Не блокирует
      # дальнейший flow если не подходит (см. VoiceIntakeProcessor.applies?).
      if Telegram::WorkBot::VoiceIntakeProcessor.applies?(msg)
        return Telegram::WorkBot::VoiceIntakeProcessor.new(msg).call
      end

      # Phase 7.5 — @mention бота в #ВОПРОС/ОТВЕТ → LLM-ответ через
      # StaffChatResponder (классификация + chat_tools/staff + escalation
      # на director если кейс не bot-resolvable).
      if Telegram::WorkBot::QnaHandler.applies?(msg)
        return Telegram::WorkBot::QnaHandler.new(msg).call
      end

      # Discovery топиков рабочей группы — пассивно: смотрим каждое сообщение,
      # которое прилетает с message_thread_id, и сохраняем маппинг key → thread_id
      # если по имени удалось определить топик. См. TopicDiscovery.
      Telegram::WorkBot::TopicDiscovery.maybe_record(msg)

      # Рабочий бот: команды в работчей группе или DM от привязанного сотрудника.
      # Router сам решает что обрабатывать (см. WorkBot::Router#call).
      workbot_result = Telegram::WorkBot::Router.new(msg).call

      # Phase 2 — хэштеги в сообщениях рабочей группы (только #ахтунг). Не блокирует
      # дальнейшую обработку — это side-effect handler. Хэштеги вне группы (DM) игнорируем.
      if msg.dig('chat', 'type') == 'supergroup' && msg['text'].to_s.match?(/#ахтунг/i)
        Telegram::WorkBot::HashtagHandler.new(msg).call
      end

      # Phase 2 hotfix — auto-discovery TG-юзеров в рабочей группе. При первом
      # сообщении от незарегистрированного создаётся TelegramUser(inactive) +
      # DM manager'у с просьбой активировать через /promote.
      if msg.dig('chat', 'type') == 'supergroup'
        Telegram::WorkBot::AutoDiscovery.new(msg).call
      end

      return workbot_result if [:handled, :verified, :code_failed].include?(workbot_result)

      # Phase 5.3 — DM staff Q&A. Если staff пишет non-command сообщение в
      # DM боту → routes to StaffChatResponder (instead of falling through
      # to inbox-saver). Команды + voice уже handled выше; этот branch для
      # natural-language questions.
      if Telegram::WorkBot::DmQnaHandler.applies?(msg)
        return Telegram::WorkBot::DmQnaHandler.call(msg)
      end

      # Inbox saver — enqueued, NOT synchronous. Telegram disconnects the
      # webhook after ~5s, and large photo/document downloads from
      # api.telegram.org easily blow past that. The job does the actual
      # save work; the webhook always returns 200 in milliseconds.
      TelegramInboxSaveJob.perform_later(msg) if Telegram::InboxSaver.whitelisted?(msg)

      reply_to_id = msg.dig('reply_to_message', 'message_id')
      return log_and_ignore('no reply_to_message_id') if reply_to_id.blank?

      conv = Conversation.find_by(telegram_message_id: reply_to_id)
      return log_and_ignore("no conversation for tg_message_id=#{reply_to_id}") unless conv

      text = msg['text'].to_s.strip
      return :ignored if text.empty?

      return handle_command(conv, text, msg) if text.start_with?('/')

      handle_reply(conv, text, msg)
      :delivered
    rescue StandardError => e
      Rails.logger.error("[Telegram::InboundProcessor] #{e.class} #{e.message}")
      :error
    end

    private

    # Phase 9 Iter 8 — Idempotency через unique update_id.
    # Возвращает true если уже видели этот update (duplicate webhook retry).
    # Ловим оба пути: ActiveRecord::RecordInvalid (uniqueness validator) +
    # ActiveRecord::RecordNotUnique (DB-level race на параллельных webhook'ах).
    def duplicate_update?
      update_id = @update['update_id']
      return false if update_id.blank?

      TelegramWebhookAck.create!(update_id: update_id, processed_at: Time.current)
      false
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      # RecordInvalid fires если уже есть запись (uniqueness validation, локаль-нейтрально).
      # RecordNotUnique fires только при race (DB-level unique constraint).
      if e.is_a?(ActiveRecord::RecordInvalid) && !e.record.errors.of_kind?(:update_id, :taken)
        raise # прочая ошибка валидации — не dedup
      end
      Rails.logger.info("[InboundProcessor] duplicate update_id=#{update_id} skipped")
      true
    rescue StandardError => e
      Rails.logger.warn("[InboundProcessor#duplicate_update?] #{e.class}: #{e.message}")
      false
    end

    # @return [Boolean] true если запись TelegramUser нашлась и была обновлена
    def touch_known_user_meta(msg)
      from_id = msg.dig('from', 'id')
      return false if from_id.blank?

      tu = TelegramUser.find_by(tg_user_id: from_id)
      return false if tu.nil?

      tu.touch_from_message!(msg)
    rescue StandardError => e
      Rails.logger.warn("[InboundProcessor#touch_known_user_meta] #{e.class}: #{e.message}")
      false
    end

    def handle_reply(conv, text, msg)
      author = resolve_author(msg)

      message = ChatMessage.create!(
        conversation: conv,
        role: :agent,
        body: text,
        author: author,
        telegram_message_id: msg['message_id']
      )

      ConversationChannel.broadcast_to(conv,
                                       type: 'message',
                                       message: serialize(message))

      Rails.logger.info("[Telegram] agent reply ##{message.id} on conversation ##{conv.id}")
    end

    def handle_command(conv, text, _msg)
      cmd, *_args = text.split(/\s+/, 2)
      case cmd.downcase
      when '/close'
        conv.update(status: :closed)
        ChatMessage.create!(conversation: conv, role: :system,
                            body: 'Диалог закрыт сотрудником.')
        ConversationChannel.broadcast_to(conv, type: 'closed')
        :closed
      else
        log_and_ignore("unknown command #{cmd}")
      end
    end

    # Telegram users have no link to our User table by default. We fall back
    # to looking up by username if it matches a User#email prefix; otherwise
    # author stays nil and we record the Telegram username in metadata.
    def resolve_author(msg)
      from = msg['from'] || {}
      username = from['username'].to_s
      return nil if username.blank?

      User.where('LOWER(email) LIKE ?', "#{username.downcase}@%").first
    end

    def serialize(m)
      {
        id: m.id,
        role: m.role,
        body: m.body,
        author: m.author&.short_name,
        created_at: m.created_at.iso8601
      }
    end

    def log_and_ignore(reason)
      Rails.logger.info("[Telegram::InboundProcessor] ignored: #{reason}")
      :ignored
    end

    # A6 Phase 1: true если сообщение — фото в личном чате (DM).
    # Telegram присылает 'photo' как массив размеров изображений.
    # Групповые фото (тип supergroup/group) — не клиентский intake.
    def client_photo_intake?(msg)
      return false unless msg['photo'].is_a?(Array) && msg['photo'].any?
      return false unless msg.dig('chat', 'type') == 'private'

      true
    end

    # Iter 60-61 — photo disposition text-continuation router.
    # После inline-кнопок step может быть:
    #   • describe_task   (Iter 60, photo→staff WITH task) → PhotoTaskContinuation
    #   • share_caption   (Iter 61, photo→staff WITHOUT task) → PhotoShareContinuation
    # ВАЖНО: `/skip` для share_caption — допустимый ввод (юзер шлёт фото без
    # подписи). Не блокируем slash-команды для этого step'а.
    #
    # @return [Symbol, nil] :handled | :error если перехвачено; nil — пропускаем
    #   ниже по pipeline (не наш кейс).
    def workbot_photo_text_continuation(msg)
      return nil unless msg.dig('chat', 'type') == 'private'

      text = msg['text'].to_s.strip
      return nil if text.empty?

      from_id = msg.dig('from', 'id')
      tg_user = ::TelegramUser.find_by(tg_user_id: from_id)
      return nil if tg_user.nil?

      pa = tg_user.pending_action
      return nil unless pa.is_a?(Hash) && pa['type'] == 'photo_disposition'

      step = pa['step'].to_s
      case step
      when 'describe_task'
        return nil if text.start_with?('/') # не /skip case — задача-режим не принимает команды
        Telegram::WorkBot::PhotoTaskContinuation.new(msg: msg, tg_user: tg_user, pending_action: pa).call
      when 'share_caption'
        # `/skip` валиден; любая slash-команда кроме /skip — пропускаем
        # (юзер передумал и пишет команду — она пойдёт в Router нормально).
        return nil if text.start_with?('/') && !text.casecmp?('/skip')
        Telegram::WorkBot::PhotoShareContinuation.new(msg: msg, tg_user: tg_user, pending_action: pa).call
      end
    rescue StandardError => e
      Rails.logger.warn("[InboundProcessor#workbot_photo_text_continuation] #{e.class}: #{e.message}")
      nil
    end
  end
end
