# frozen_string_literal: true

# Async LLM reply: when the user posts a message, MessagesController enqueues
# this job. The job calls Llm::ChatResponder, saves the assistant reply,
# broadcasts it to the visitor's WebSocket channel, and triggers
# Telegram escalation if the LLM raised the marker.
class LlmReplyJob < ApplicationJob
  queue_as :default

  def perform(conversation_id, message_id = nil)
    conv = Conversation.find_by(id: conversation_id)
    return unless conv && !conv.status_closed?

    # Тест-режим прогона чат-бота (issue #214) + IP/UA посетителя (issue #275):
    # qualify_lead и соседние тулы создают лиды/оценки в этом треде — им нужны
    # metadata['test'] и ip_address/user_agent для карточки лида. Thread-local,
    # по аналогии с Thread.current[:skip_workbot_push] в Lead::Intake::SiteSource.
    message = message_id ? conv.chat_messages.find_by(id: message_id) : nil
    result = with_lead_request_context(conv, message) do
      Llm::ChatResponder.new(conv, page_ctx: message_page_snapshot(message)).call
    end

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

  # Ставит thread-local контекст запроса (тест-режим + IP/UA посетителя из
  # metadata триггерного сообщения) на время LLM-прогона и снимает его даже
  # при исключении — иначе значения протекут в следующий job этого воркера.
  def with_lead_request_context(conv, message)
    Thread.current[:lead_test_mode] = conv.test_probe?
    meta = message&.metadata.is_a?(Hash) ? message.metadata : {}
    Thread.current[:lead_client_ip] = meta['ip'].presence
    Thread.current[:lead_client_user_agent] = meta['user_agent'].presence
    yield
  ensure
    Thread.current[:lead_test_mode] = false
    Thread.current[:lead_client_ip] = nil
    Thread.current[:lead_client_user_agent] = nil
  end

  # Снимок страницы на момент конкретного вопроса (см. MessagesController).
  # Для старых job без message_id — nil, ChatResponder упадёт на
  # conversation.metadata['page'] как раньше.
  def message_page_snapshot(message)
    message&.metadata.is_a?(Hash) ? message.metadata['page'] : nil
  end

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
