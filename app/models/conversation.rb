# frozen_string_literal: true

# Public chat-widget conversation. Tracks visitor identity, agent assignment,
# escalation state, and the Telegram root message id for staff reply matching.
class Conversation < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :assigned_user, class_name: 'User', optional: true
  has_many :chat_messages, -> { order(:created_at) }, dependent: :destroy

  enum :status, { active: 0, escalated: 1, closed: 2 }, prefix: :status

  scope :for_visitor, ->(token) { where(visitor_token: token) }
  scope :open_state, -> { where(status: %i[active escalated]) }

  # Renders messages in OpenAI-compatible chat format for LLM API calls.
  # Skips system rows (system prompt is rebuilt per request).
  # Hard cap: 30 messages × 1000 chars each — protects against context-flooding
  # attacks ("заливаем мусор чтобы выпихнуть системный промпт") and runaway costs.
  PER_MSG_CHAR_CAP = 1000

  def history_for_llm(limit: 30)
    chat_messages
      .where.not(role: ChatMessage.roles[:system])
      .last(limit)
      .map { |m| { role: m.llm_role, content: m.body.to_s[0, PER_MSG_CHAR_CAP] } }
  end

  def escalate!(reason: nil)
    return if status_escalated? || status_closed?
    update!(
      status: :escalated,
      escalated_at: Time.current,
      metadata: metadata.to_h.merge('escalation_reason' => reason)
    )
  end

  def display_name
    name.presence || (user&.short_name) || 'Аноним'
  end
end
