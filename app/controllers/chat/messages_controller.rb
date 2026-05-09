# frozen_string_literal: true

module Chat
  # POSTs from the public chat widget. Saves the user message, broadcasts
  # an immediate echo so the widget can render it without optimistic UI,
  # then enqueues LlmReplyJob for the asynchronous LLM response.
  #
  # Light rate-limit: 5 messages/minute per visitor_token via Redis.
  class MessagesController < ApplicationController
    skip_before_action :verify_authenticity_token, only: %i[create], raise: false

    RATE_LIMIT_PER_MINUTE = 5

    def create
      conv = Conversation.for_visitor(current_visitor_token).open_state.first
      conv ||= Conversation.create!(
        visitor_token:   current_visitor_token,
        user_id:         current_user&.id,
        status:          :active,
        last_message_at: Time.current
      )

      return render(json: { error: 'rate_limited' }, status: :too_many_requests) if rate_limited?

      body = params[:body].to_s.strip
      return render(json: { error: 'empty_body' }, status: :unprocessable_entity) if body.empty?
      return render(json: { error: 'too_long' },   status: :unprocessable_entity) if body.length > 2000

      msg = ChatMessage.create!(
        conversation: conv,
        role:         :user,
        body:         body,
        author:       current_user
      )

      ConversationChannel.broadcast_to(conv,
        type:    'message',
        message: serialize(msg)
      )

      verdict = Llm::ScopeGuard.classify(body)
      if verdict == :allowed
        LlmReplyJob.perform_later(conv.id)
      else
        post_static_reply(conv, verdict, body)
      end

      render json: { ok: true, message_id: msg.id }, status: :created
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    private

    # ScopeGuard short-circuit: write the canned reply right here (no LLM call,
    # no token spend), broadcast it, log the security event for later review.
    def post_static_reply(conv, verdict, original_body)
      reply = ChatMessage.create!(
        conversation: conv,
        role:         :assistant,
        body:         Llm::ScopeGuard::REPLIES[verdict],
        metadata:     { kind: 'scope_guard', verdict: verdict.to_s }
      )

      ConversationChannel.broadcast_to(conv,
        type:    'message',
        message: serialize(reply)
      )

      record_security_event(conv, verdict, original_body)
    end

    def record_security_event(conv, verdict, original_body)
      meta = conv.metadata.is_a?(Hash) ? conv.metadata.dup : {}
      events = (meta['security_events'] || [])
      events << { at: Time.current.iso8601, kind: verdict.to_s, excerpt: original_body.to_s.truncate(200) }
      meta['security_events'] = events.last(50) # keep it bounded
      conv.update_columns(metadata: meta)

      Rails.logger.warn("[ScopeGuard] visitor=#{current_visitor_token} verdict=#{verdict} excerpt=#{original_body.to_s.truncate(120).inspect}") if verdict == :injection
    end

    # Redis sliding-window: count INCR per visitor within the last 60s.
    def rate_limited?
      key = "chat:rate:#{current_visitor_token}"
      count = Sidekiq.redis { |r| r.incr(key) }
      Sidekiq.redis { |r| r.expire(key, 60) } if count == 1
      count.to_i > RATE_LIMIT_PER_MINUTE
    rescue StandardError
      false
    end

    def serialize(m)
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
