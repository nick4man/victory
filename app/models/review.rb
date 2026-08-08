# frozen_string_literal: true

class Review < ApplicationRecord
  # ============================================
  # CONSTANTS
  # ============================================

  SOURCES = %w[own yandex 2gis google avito other].freeze
  SUBMITTED_VIAS = %w[web_form chat_bot admin import].freeze

  # ============================================
  # ASSOCIATIONS
  # ============================================

  # Anonymous web form, chat-bot pickup, copy-paste from external platforms —
  # all of these submit reviews without an authenticated user.
  belongs_to :user, optional: true
  belongs_to :property, optional: true
  belongs_to :agent, class_name: 'User', optional: true

  # ============================================
  # ENUMS
  # ============================================

  # Schema column is integer (0..3); migration comment lists 0=pending 1=approved 2=rejected 3=hidden.
  enum :status, { pending: 0, approved: 1, rejected: 2, hidden: 3 }, prefix: true

  # ============================================
  # VALIDATIONS
  # ============================================

  validates :rating, presence: true, numericality: { only_integer: true, in: 1..5 }
  # Schema column is :body, not :content. Validate the actual column.
  validates :body, presence: true, length: { in: 10..1000 }
  validates :title, length: { maximum: 255 }, allow_blank: true
  validates :source, inclusion: { in: SOURCES }
  validates :submitted_via, inclusion: { in: SUBMITTED_VIAS }, allow_nil: true
  validates :author_name, presence: true, if: -> { user_id.blank? }
  validates :external_url,
            format: { with: URI::DEFAULT_PARSER.make_regexp(%w[http https]) },
            allow_blank: true

  # ============================================
  # SCOPES
  # ============================================

  scope :recent,        -> { order(created_at: :desc) }
  scope :approved_only, -> { status_approved }
  scope :pending_only,  -> { status_pending }
  scope :rejected_only, -> { status_rejected }
  scope :high_rated,    -> { where('rating >= ?', 4) }
  scope :low_rated,     -> { where('rating <= ?', 2) }
  scope :for_property,  ->(property_id) { where(property_id: property_id) }
  scope :for_agent,     ->(agent_id) { where(agent_id: agent_id) }
  scope :public_facing, -> { status_approved.order(rating: :desc, created_at: :desc) }
  scope :from_own,      -> { where(source: 'own') }
  scope :from_external, -> { where.not(source: 'own') }

  # ============================================
  # CALLBACKS
  # ============================================

  after_commit :bust_metrics_cache, on: %i[create update destroy]

  # ============================================
  # INSTANCE METHODS
  # ============================================

  def approve!
    update(status: 'approved', moderated_at: Time.current)
  end

  def reject!(reason = nil)
    update(status: 'rejected', moderated_at: Time.current, moderation_notes: reason)
  end

  def moderated?
    moderated_at.present?
  end

  def stars
    '★' * rating + '☆' * (5 - rating)
  end

  def rating_percentage
    (rating.to_f / 5.0 * 100).round
  end

  def status_humanized
    I18n.t("activerecord.attributes.review.statuses.#{status}", default: status.humanize)
  end

  def display_author
    user&.full_name.presence || author_name.presence || 'Аноним'
  end

  def display_initials
    name = display_author
    return '??' if name == 'Аноним'

    parts = name.split(/\s+/, 2).map { |w| w[0]&.upcase }.compact
    parts.join.presence || '??'
  end

  def source_label
    case source
    when 'yandex' then 'Яндекс.Карты'
    when '2gis'   then '2ГИС'
    when 'google' then 'Google'
    when 'avito'  then 'Авито'
    when 'own'    then nil # без бейджа
    else               source&.humanize
    end
  end

  private

  def bust_metrics_cache
    AgencyMetricsService.bust!
  end
end
