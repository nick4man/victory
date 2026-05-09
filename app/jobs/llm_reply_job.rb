# frozen_string_literal: true

# Async LLM reply: when the user posts a message, MessagesController enqueues
# this job. The job calls Llm::ChatResponder, saves the assistant reply,
# broadcasts it to the visitor's WebSocket channel, and triggers
# Telegram escalation if the LLM raised the marker.
class LlmReplyJob < ApplicationJob
  queue_as :default

  def perform(conversation_id)
    conv = Conversation.find_by(id: conversation_id)
    return unless conv && !conv.status_closed?

    result = Llm::ChatResponder.new(conv).call

    msg = ChatMessage.create!(
      conversation: conv,
      role:         :assistant,
      body:         result[:reply],
      metadata:     {
        model:    result[:model],
        escalate: result[:escalate]
      }
    )

    ConversationChannel.broadcast_to(conv,
      type:    'message',
      message: message_payload(msg)
    )

    return unless result[:escalate]

    if conv.status_active?
      conv.escalate!(reason: result[:summary])
      ConversationChannel.broadcast_to(conv, type: 'status_changed', status: 'escalated')
    end

    TelegramNotifyJob.perform_later(conv.id, result[:summary])
  end

  private

  # NB: do not name this `serialize` — it shadows ActiveJob#serialize and breaks enqueue.
  def message_payload(m)
    {
      id:         m.id,
      role:       m.role,
      body:       m.body,
      author:     m.author&.short_name,
      created_at: m.created_at.iso8601
    }
  end
end
