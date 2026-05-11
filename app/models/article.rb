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

  CATEGORIES = %w[market guides news investment mortgage].freeze
  SCHEMA_TYPES = %w[NewsArticle BlogPosting].freeze

  validates :title, presence: true, length: { minimum: 10, maximum: 200 }
  validates :body,  presence: true
  validates :category, inclusion: { in: CATEGORIES }
  validates :schema_type, inclusion: { in: SCHEMA_TYPES }

  before_save :render_markdown, if: :body_changed?

  scope :published,   -> { where.not(published_at: nil).where('published_at <= ?', Time.current) }
  scope :recent,      -> { order(published_at: :desc) }
  scope :in_category, ->(cat) { where(category: cat) if cat.present? }
  scope :for_region,  ->(reg) { where('region IS NULL OR region = ?', reg) if reg.present? }

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
end
