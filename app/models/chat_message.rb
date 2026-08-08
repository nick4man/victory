# frozen_string_literal: true

# Single message in a Conversation. role enum:
#   user      → visitor (cookie-identified or logged-in)
#   assistant → LLM auto-reply
#   agent     → staff reply (typed in Telegram or admin UI)
#   system    → housekeeping (escalation notice, "agent connected", etc.)
class ChatMessage < ApplicationRecord
  belongs_to :conversation, touch: :last_message_at
  belongs_to :author, class_name: 'User', optional: true

  enum :role, { user: 0, assistant: 1, agent: 2, system: 3 }, prefix: :role

  validates :body, presence: true, length: { maximum: 5000 }

  scope :recent, -> { order(:created_at) }

  # Maps to OpenAI-compatible chat role: agent (staff) is sent as `assistant`
  # so the LLM treats it as same-side history when continuing the conversation.
  def llm_role
    case role
    when 'user'   then 'user'
    when 'system' then 'system'
    else               'assistant'
    end
  end
end
