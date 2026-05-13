# frozen_string_literal: true

# Blog / market-report content. Markdown source in `body`; rendered HTML
# cached in `body_html` (regenerated whenever body changes). Slugs are
# transliterated via the same Cyrillic→Latin map as Property — reuses
# Property::CYRILLIC_TO_LATIN to avoid duplication.
#
# Categories (loose taxonomy, can grow):
#   - 'market'      : weekly market reports (Phase 2 cadence)
#   - 'guides'      : evergreen buyer/seller guides
#   - 'news'        : agency or industry news
#   - 'investment'  : investor-facing analytics (Phase 3)
#   - 'mortgage'    : mortgage tips / programs
#
# schema_type drives the Schema.org @type in JSON-LD: 'NewsArticle' for
# market/news (datePublished matters), 'BlogPosting' for evergreen guides.
class Article < ApplicationRecord
  extend FriendlyId
  friendly_id :title, use: %i[slugged history finders]

  belongs_to :author, class_name: 'User', optional: true
  has_one :article_embedding, dependent: :destroy

  CATEGORIES = %w[market guides news investment mortgage].freeze
  SCHEMA_TYPES = %w[NewsArticle BlogPosting].freeze
  # External-source tag stored in `external_source` — provenance for
  # webhook-ingested content. `manual` covers admin-created entries.
  EXTERNAL_SOURCES = %w[chat_urgent chat_digest manual macro_snapshot].freeze

  # Cross-link defaults for the Telegram channel. The chat-host publisher
  # passes these per-article via webhook (Phase 8) so we can support
  # multiple channels later, but in practice they're constant — used as
  # graceful fallback when metadata is missing or for manually-created
  # articles that didn't go through the webhook.
  TELEGRAM_FALLBACK_URL    = 'https://t.me/rznvictory'
  TELEGRAM_FALLBACK_HANDLE = '@rznvictory'

  validates :title, presence: true, length: { minimum: 10, maximum: 200 }
  validates :body,  presence: true
  validates :category, inclusion: { in: CATEGORIES }
  validates :schema_type, inclusion: { in: SCHEMA_TYPES }

  before_save :render_markdown, if: :body_changed?
  after_commit :enqueue_embedding, on: %i[create update]
  after_commit :notify_indexnow_on_publish, on: %i[create update],
               if: :should_notify_indexnow?

  scope :published,    -> { where.not(published_at: nil).where('published_at <= ?', Time.current) }
  scope :recent,       -> { order(published_at: :desc) }
  scope :visible,      -> { where(hidden_at: nil) }
  scope :public_facing,-> { published.visible.recent }
  scope :in_category,  ->(cat) { where(category: cat) if cat.present? }
  scope :for_region,   ->(reg) { where('region IS NULL OR region = ?', reg) if reg.present? }

  def hidden?
    hidden_at.present?
  end

  def hide!
    update!(hidden_at: Time.current)
  end

  def unhide!
    update!(hidden_at: nil)
  end

  def published?
    published_at.present? && published_at <= Time.current
  end

  # Telegram channel link/handle — per-article override via metadata,
  # fallback to the agency default. Works for old articles that don't
  # carry the new payload fields too.
  def telegram_channel_url
    meta_value('telegram_channel_url').presence || TELEGRAM_FALLBACK_URL
  end

  def telegram_channel_handle
    meta_value('telegram_channel_handle').presence || TELEGRAM_FALLBACK_HANDLE
  end

  def hashtags
    Array(meta_value('hashtags')).compact_blank
  end

  # Reuses Property's transliteration map — avoids duplicating the GOST
  # 7.79-2000 table that's already proven on slugs in Cycle 1.
  def normalize_friendly_id(value)
    Property.transliterate_to_latin(value).parameterize
  end

  # Truncated body for cards / OG description. Plain text from rendered HTML
  # so cards don't carry inline markup.
  def short_excerpt(length: 220)
    return excerpt.to_s.strip if excerpt.present?

    text = ActionView::Base.full_sanitizer.sanitize(body_html.to_s)
    text = body if text.blank?
    text.to_s.strip.gsub(/\s+/, ' ').truncate(length)
  end

  # Estimated read time in minutes (200 wpm convention).
  def reading_minutes
    word_count = body.to_s.split(/\s+/).size
    [(word_count / 200.0).ceil, 1].max
  end

  private

  # metadata is a jsonb column — keys may come back as strings (chat-host
  # webhook) or symbols (admin form via strong-params). Read both.
  def meta_value(key)
    return nil if metadata.blank?
    metadata[key.to_s] || metadata[key.to_sym]
  end

  # Re-embed when content-shaping fields changed, OR if we never embedded yet.
  # category/region/metadata change embedding because ArticleTextTemplate
  # includes them as structured frontmatter — affects cosine-NN clustering.
  def enqueue_embedding
    relevant = saved_change_to_body? || saved_change_to_title? ||
               saved_change_to_metadata? || saved_change_to_category? ||
               saved_change_to_region?
    return unless relevant || article_embedding.nil?
    EmbedArticleJob.perform_later(id)
  end

  def render_markdown
    renderer = Redcarpet::Render::HTML.new(
      hard_wrap: true,
      safe_links_only: true,
      with_toc_data: false
    )
    md = Redcarpet::Markdown.new(renderer,
                                 autolink: true,
                                 tables: true,
                                 fenced_code_blocks: true,
                                 strikethrough: true,
                                 superscript: true)
    self.body_html = md.render(body.to_s).html_safe
  end

  # Push IndexNow notification when article transitions to public state
  # (published_at set, hidden_at clear). Skipped silently if
  # INDEXNOW_API_KEY is unset or we're not in production.
  def should_notify_indexnow?
    return false if hidden_at.present?
    return false if published_at.blank? || published_at > Time.current

    return true if previously_new_record?
    saved_change_to_published_at? ||
      saved_change_to_hidden_at? ||
      saved_change_to_title? ||
      saved_change_to_body?
  end

  def notify_indexnow_on_publish
    url = Rails.application.routes.url_helpers.article_url(
      self,
      host: 'victory62.org',
      protocol: 'https'
    )
    Seo::IndexNowNotifyJob.perform_later(url: url)
  end
end
