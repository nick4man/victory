# frozen_string_literal: true

# Phase 7.5 — Вопросы сотрудников в #ВОПРОС/ОТВЕТ топике.
# Источник KPI metric `questions_asked` (Phase 7.6) — показатель автономности
# сотрудника (низкий questions/tasks = высокая автономия).
#
# kind:
#   clarification — детали по задаче/лиду; bot can answer with chat_tools/staff
#   information   — общее знание/прайс/процедура; bot отвечает из system prompt
#   escalation    — нужен manager (клиент требует, конфликт, нестандарт)
class CreateStaffQuestions < ActiveRecord::Migration[7.1]
  def change
    create_table :staff_questions do |t|
      t.bigint   :asked_by_id, null: false # FK логический → telegram_users
      t.bigint   :related_task_id                      # FK логический → tasks
      t.bigint   :related_lead_event_id                # FK логический → lead_events
      t.string   :kind                                 # clarification|information|escalation
      t.text     :question_text, null: false
      t.text     :answer_text                          # bot/manager response
      t.bigint   :answered_by_id                       # FK логический → telegram_users (manager в escalation)
      t.bigint   :escalated_to_id                      # FK логический → telegram_users (manager pinged)
      t.bigint   :tg_message_id                        # id вопроса в #qna топике (для reply-tracking)
      t.bigint   :tg_chat_id
      t.bigint   :tg_thread_id
      t.string   :llm_model                            # какой OmniClient model ответил
      t.float    :classifier_confidence                # 0-1, из QuestionClassifier
      t.datetime :answered_at
      t.datetime :deleted_at, index: true
      t.timestamps
    end

    add_index :staff_questions, [:asked_by_id, :created_at]
    add_index :staff_questions, :kind
    add_index :staff_questions, :related_task_id
    add_index :staff_questions, :related_lead_event_id
    add_index :staff_questions, :tg_message_id
  end
end
