# frozen_string_literal: true

module Chat
  # Singleton conversation per visitor (one open conversation per browser cookie).
  # Anonymous visitors are identified by the signed visitor_token cookie.
  class ConversationsController < ApplicationController
    include Chat::PageContextParams
    include Chat::TestModeResolution

    skip_before_action :verify_authenticity_token, only: %i[show update activate_test], raise: false

    # GET /chat/conversation[?page[path]=&page[title]=&page[query]=&page[referrer]=]
    # Returns or lazily-creates the visitor's active conversation, with full history.
    # Seeds an assistant welcome message on first visit, page-context-aware when
    # the widget passes its `page` payload. We always refresh metadata['page']
    # (a single visitor can navigate between pages while the conversation is open).
    def show
      @conversation = current_or_create_conversation
      page_ctx = extract_page_params
      stamp_page(@conversation, page_ctx) if page_ctx
      # Кран/origin/IP включились посреди разговора — дорисовываем маркер.
      ensure_conversation_test_mode!(@conversation)
      seed_welcome(@conversation, page_ctx) if @conversation.chat_messages.empty?

      respond_to do |format|
        format.json { render json: serialize(@conversation) }
      end
    end

    # PATCH /chat/conversation
    # Update lead info: { name, phone, email }.
    def update
      @conversation = current_or_create_conversation
      attrs = params.permit(:name, :phone, :email).to_h.compact_blank
      @conversation.update(attrs)
      render json: serialize(@conversation)
    end

    # POST /chat/conversation/activate_test — тумблер «🧪 Тест-прогон»
    # виджета (issue #249). Выдача probe-токена ТОЛЬКО по секрету probe_key
    # (блокер ревью #230: публичного ENDPOINT'а, раздающего токены анонимам,
    # нет и быть не может). Токен выпускается в cookie ЭТОГО визита —
    # пригодный для подмены чужой сессии артефакт наружу не отдаём:
    # ответ содержит только ok/статус, не сам токен. Дальше виджет
    # перезагружает диалог, контроллеры помечают metadata['test_probe'].
    def activate_test
      return render(json: { error: 'invalid_secret' }, status: :forbidden) unless probe_secret_valid?

      old_token = current_visitor_token
      set_visitor_cookies(SecureRandom.hex(16), probe: true)
      # Диалоги старого токена закрываем: bootstrap по новому токену создаст
      # новый — уже с маркером тест-контура. Новый токен диалогов не имел.
      Conversation.for_visitor(old_token).open_state.update_all(status: Conversation.statuses[:closed])
      render json: { ok: true }
    end

    private

    def current_or_create_conversation
      Conversation.for_visitor(current_visitor_token).open_state.first ||
        Conversation.create!(
          visitor_token:   current_visitor_token,
          user_id:         current_user&.id,
          status:          :active,
          last_message_at: Time.current,
          # Тест-контур (issue #214/#229/#249): probe-cookie из #228, кран
          # ENV и доверенные origin/IP — все сводятся к metadata-маркеру.
          metadata:        conversation_test_metadata
        )
    end

    def seed_welcome(conv, page_ctx = nil)
      ChatMessage.create!(
        conversation: conv,
        role:         :assistant,
        body:         Llm::PageGreeting.for(page_ctx),
        metadata:     { seeded: true, kind: 'auto_greeting', page: page_ctx }.compact
      )
    end

    # POST /chat/conversation/activate_test (issue #249): секрет из body,
    # проверка тем же digest-сравнением, что и probe-активация из #228
    # (VisitorIdentity#probe_secret_valid?). Пустой ENV на сервере = отказ,
    # как у вебхуков.
    def probe_secret_valid?
      configured = probe_secret
      if configured.blank?
        Rails.logger.warn('[Chat::ConversationsController] тест-прогон отключён: CHAT_PROBE_SECRET/ADMIN_TOKEN не заданы')
        return false
      end

      submitted = params[:probe_key].to_s
      return false if submitted.blank?

      ActiveSupport::SecurityUtils.secure_compare(
        Digest::SHA256.hexdigest(submitted),
        Digest::SHA256.hexdigest(configured)
      )
    end

    def probe_secret
      ENV['CHAT_PROBE_SECRET'].presence || ENV['ADMIN_TOKEN'].presence
    end

    # extract_page_params / stamp_page — в консерне Chat::PageContextParams
    # (общий с Chat::MessagesController, который шлёт page с каждым сообщением).

    def serialize(conv)
      {
        id:       conv.id,
        status:   conv.status,
        name:     conv.name,
        phone:    conv.phone,
        email:    conv.email,
        messages: conv.chat_messages.recent.map { |m| serialize_message(m) }
      }
    end

    def serialize_message(m)
      {
        id:         m.id,
        role:       m.role,
        body:       m.body,
        author:     m.author&.short_name,
        created_at: m.created_at.iso8601
      }
    end
  end
end
