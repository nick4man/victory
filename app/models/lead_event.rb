# frozen_string_literal: true

# Состояние конвейера обработки лида в Telegram-боте АН.
# Один LeadEvent = один лид + его представление в TG-чате (карточка-якорь в
# текущем специализированном топике + опциональный тизер в #СДЕЛКА).
#
# Жизненный цикл:
#   1. Lead::Intake создаёт запись с anchor_topic_key='dispatcher'
#   2. /route переносит anchor в специализированный топик (apartments, mortgage, …)
#   3. /assign фиксирует assigned_to + assigned_at + first SLA-таймер
#   4. /stage обновляет current_stage; при 'contract'/'deal' создаётся deal_mirror в #СДЕЛКА
#   5. /close выставляет closed_at + current_stage='closed_won'/'closed_lost'
class LeadEvent < ApplicationRecord
  SOURCES = ['site_form', 'site_valuation', 'site_mortgage', 'tg_dm', 'manual', 'crm_webhook'].freeze
  STAGES  = ['new', 'first_contact', 'show', 'contract', 'deal', 'closed_won', 'closed_lost'].freeze
  TOPIC_KEYS = [
    'dispatcher',
    'apartments',
    'houses',
    'lots',
    'commercial',
    'rent',
    'mortgage',
    'appraisal',
    'taxes',
    'insurance',
    'escrow',
    'deal'
  ].freeze

  belongs_to :lead_ref, polymorphic: true
  belongs_to :assigned_to, class_name: 'TelegramUser', optional: true

  validates :source,           inclusion: { in: SOURCES }
  validates :current_stage,    inclusion: { in: STAGES }
  validates :anchor_topic_key, inclusion: { in: TOPIC_KEYS }
  validates :tg_chat_id, presence: true

  scope :open,     -> { where.not(current_stage: ['closed_won', 'closed_lost']) }
  scope :closed,   -> { where(current_stage: ['closed_won', 'closed_lost']) }
  scope :for_agent, ->(tg_user) { where(assigned_to: tg_user) }
  scope :awaiting_first_contact, lambda {
    where(first_contact_at: nil)
      .where.not(assigned_at: nil)
      .where.not(current_stage: ['closed_won', 'closed_lost'])
  }
  scope :in_topic, ->(key) { where(anchor_topic_key: key) }

  def open?
    !closed?
  end

  def closed?
    ['closed_won', 'closed_lost'].include?(current_stage)
  end

  def assigned?
    assigned_to_id.present?
  end

  # Telegram t.me deep-link to the current anchor message — для тизеров и SLA-пингов.
  # Два формата (см. Telegram client behavior):
  #   • Forum topic: t.me/c/<chat-без-100>/<thread_id>/<message_id>
  #   • General / non-forum group: t.me/c/<chat-без-100>/<message_id>
  # tg_chat_id для supergroup негативный с префиксом -100; в URL без него.
  def anchor_url
    return nil if anchor_message_id.blank? || tg_chat_id.blank?

    chat = tg_chat_id.to_s.delete_prefix('-100')
    if anchor_thread_id.present?
      "https://t.me/c/#{chat}/#{anchor_thread_id}/#{anchor_message_id}"
    else
      # General topic: TG не использует thread_id в URL (или dropped == 1).
      "https://t.me/c/#{chat}/#{anchor_message_id}"
    end
  end
end
