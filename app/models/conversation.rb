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

  # Тестовый прогон чат-виджета (issue #214): visitor_token с префиксом
  # probe- (задаётся через ?visitor_token=probe-<name>). Лиды такого диалога
  # помечаются metadata['test'] и публикуются в тестовый TG-чат, а не в
  # ДИСПЕТЧЕРСКУЮ.
  def test_probe?
    visitor_token.to_s.start_with?('probe-')
  end

  # Issue #227: сессия с не-прод хоста / офисного IP помечена контроллером
  # флагом metadata['auto_test'] — лиды идут в тестовый чат без тумблера.
  def auto_test?
    metadata.is_a?(Hash) && metadata['auto_test'] == true
  end

  # Полный тест-режим сессии (issue #227): probe-тумблер, auto-test по
  # происхождению или ENV-кран SITE_CHATBOT_FORCE_TEST. Читается LlmReplyJob
  # — Thread.current[:lead_test_mode] → ChatTools помечают лиды/оценки.
  def lead_test_mode?
    test_probe? || auto_test? || Chat::TestMode.force_test?
  end

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
