# frozen_string_literal: true

module Chat
  # Singleton conversation per visitor (one open conversation per browser cookie).
  # Anonymous visitors are identified by the signed visitor_token cookie.
  class ConversationsController < ApplicationController
    include Chat::PageContextParams

    skip_before_action :verify_authenticity_token, only: %i[show update], raise: false

    # GET /chat/conversation[?page[path]=&page[title]=&page[query]=&page[referrer]=]
    # Returns or lazily-creates the visitor's active conversation, with full history.
    # Seeds an assistant welcome message on first visit, page-context-aware when
    # the widget passes its `page` payload. We always refresh metadata['page']
    # (a single visitor can navigate between pages while the conversation is open).
    def show
      @conversation = current_or_create_conversation
      page_ctx = extract_page_params
      stamp_page(@conversation, page_ctx) if page_ctx
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

    private

    def current_or_create_conversation
      Conversation.for_visitor(current_visitor_token).open_state.first ||
        Conversation.create!(
          visitor_token:   current_visitor_token,
          user_id:         current_user&.id,
          status:          :active,
          last_message_at: Time.current
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
