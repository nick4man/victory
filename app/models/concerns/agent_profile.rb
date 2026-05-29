# frozen_string_literal: true

# Agent profile concern for User. Adds:
#   - `agent_slug` auto-generation on save for role=agent users
#   - to_param override so /agents/:slug routes resolve via slug
#   - aggregate helpers for approved Review records linked to the agent
#
# Why a concern, not inline in User: User is a complex Devise+Topnlab-synced
# model; isolating agent-only behaviour keeps the auth/identity surface
# clean and lets tests stub the concern independently.
module AgentProfile
  extend ActiveSupport::Concern

  included do
    before_save :generate_agent_slug, if: :should_generate_agent_slug?

    # Approved reviews where THIS user is the agent (not the property owner).
    has_many :received_reviews, -> { status_approved },
             class_name: 'Review', foreign_key: 'agent_id'

    # Agents that should appear at /agents/:slug and in sitemap. Filters out
    # system accounts (Topnlab Import, "удалён Пользователь"), users without
    # a CRM department, blocked CRM statuses, и тех кто явно запросил «убрать
    # с сайта» (152-ФЗ — `public_profile_hidden_at` timestamp). Used by
    # AgentsController и SitemapController; kept as a scope so DB does the
    # filtering.
    scope :publicly_listable_agents, lambda {
      # Phone is preferred but not required — some agents work email-only.
      # crm_status + department_id together filter out the system accounts
      # (Topnlab Import has crm_status='', "удалён Пользователь" passes both
      # but is caught by the last_name guard).
      where(role: :agent, active: true, deleted_at: nil, crm_status: 'active')
        .where.not(agent_slug: [nil, ''])
        .where.not(department_id: nil)
        .where('LOWER(last_name) != ?', 'пользователь')
        .where(public_profile_hidden_at: nil)
    }
  end

  # Override Rails' default to_param. For agents we surface the latin-slug
  # URL; for everyone else the bare id stays (admin/dashboard internal use).
  def to_param
    agent_slug.presence || super
  end

  def agent_average_rating
    return nil unless role_agent?
    @agent_average_rating ||= received_reviews.average(:rating)&.to_f&.round(2)
  end

  def agent_review_count
    return 0 unless role_agent?
    @agent_review_count ||= received_reviews.count
  end

  # True iff this user passes the same gate as `publicly_listable_agents`.
  # Used by views (team card link, property show «КОНТАКТ АГЕНТА» block)
  # без extra DB query.
  def has_agent_profile?
    role_agent? &&
      active? &&
      !deleted? &&
      agent_slug.present? &&
      crm_status == 'active' &&
      department_id.present? &&
      last_name.to_s.downcase != 'пользователь' &&
      !public_profile_hidden_from_site?
  end

  # 152-ФЗ — true когда агент попросил снять публичный профиль с сайта.
  # `respond_to?` guard для безопасной работы до миграции (production rollout
  # с feature-flag pattern).
  def public_profile_hidden_from_site?
    respond_to?(:public_profile_hidden_at) && public_profile_hidden_at.present?
  end

  private

  def should_generate_agent_slug?
    role_agent? && agent_slug.blank? && (first_name.present? || last_name.present?)
  end

  # Transliterate "Иван Петров" → "ivan-petrov". Reuses the Property GOST
  # 7.79-2000 map established in Cycle 1 to keep one slug pipeline.
  # On collision, appends a numeric suffix until a free slug is found.
  def generate_agent_slug
    base_name = [first_name, last_name].compact_blank.join(' ').strip
    return if base_name.blank?

    base = Property.transliterate_to_latin(base_name).parameterize
    return if base.blank?

    candidate = base
    suffix = 2
    while User.where(agent_slug: candidate).where.not(id: id).exists?
      candidate = "#{base}-#{suffix}"
      suffix += 1
    end
    self.agent_slug = candidate
  end

  def deleted?
    respond_to?(:deleted_at) ? deleted_at.present? : false
  end
end
