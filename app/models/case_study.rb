# frozen_string_literal: true

# == Schema Information
#
# Table name: case_studies
#
#  id                  :bigint           not null, primary key
#  title               :string           not null
#  slug                :string           not null
#  excerpt             :text
#  body                :text             not null
#  body_html           :text
#  client_alias        :string
#  client_origin       :string
#  client_profession   :string
#  district            :string
#  property_type       :integer          default("flat"), not null
#  area                :decimal(8, 2)
#  deal_amount         :bigint
#  deal_duration_days  :integer
#  bank                :string
#  mortgage_program    :string
#  author_id           :bigint
#  inquiry_id          :bigint
#  property_id         :bigint
#  meta_title          :string
#  meta_description    :string
#  og_image_url        :string
#  status              :integer          default("draft"), not null
#  published_at        :datetime
#  deleted_at          :datetime
#  views_count         :integer          default(0), not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#
# Анонимизированный кейс по закрытой сделке. Активирует Pillar 2
# стратегического вектора («глубокая экспертиза» через proof of past
# performance). Pipeline: case-study-writer agent драфтит markdown body
# → admin публикует через /admin/case_studies → public видит на
# /cases/:slug.
#
# Soft-delete через deleted_at + default_scope (project convention).
# Hidden vs deleted vs archived — это три разных state'а:
#
#   * status = draft     — невидимый, идёт работа над текстом
#   * status = published — публичный, показан на /cases
#   * status = archived  — устарел, скрыт из public-listing'а но
#                           доступен в админке (для архивирования)
#   * deleted_at != nil  — soft-deleted, default_scope полностью скрывает
class CaseStudy < ApplicationRecord
  extend FriendlyId
  friendly_id :title, use: %i[slugged history finders]

  belongs_to :author,   class_name: 'User', optional: true
  belongs_to :inquiry,  optional: true
  belongs_to :property, optional: true

  # Cover image — admin-uploadable hero/preview. Когда attached, прерывает
  # fallback chain в #og_image_url (которая иначе тянет default). OG-вариант
  # crops к 1200×630 ровно под Telegram/VK/Дзен preview-card aspect.
  #
  # OG variant остаётся ТОЛЬКО JPEG — social-card crawlers (VK/Telegram/Дзен)
  # многие не понимают WebP/AVIF, parse failure = no preview. Hero и card
  # получают webp/avif для in-page рендеринга через будущий picture-helper.
  has_one_attached :cover_image do |attachable|
    attachable.variant :hero,      resize_to_limit: [1920, 1080], saver: { quality: 85, strip: true }
    attachable.variant :hero_webp, resize_to_limit: [1920, 1080], format: :webp, saver: { quality: 82, strip: true }
    attachable.variant :hero_avif, resize_to_limit: [1920, 1080], format: :avif, saver: { quality: 72, strip: true }
    attachable.variant :og,        resize_to_fill:  [1200, 630],  saver: { quality: 82, strip: true }
    attachable.variant :card,      resize_to_limit: [800, 600],   saver: { quality: 80, strip: true }
    attachable.variant :card_webp, resize_to_limit: [800, 600],   format: :webp, saver: { quality: 80, strip: true }
    attachable.variant :card_avif, resize_to_limit: [800, 600],   format: :avif, saver: { quality: 70, strip: true }
  end

  # property_type значения 1:1 совпадают с Property enum чтобы кейс с
  # привязанным property_id мог корректно унаследовать или переопределить
  # тип в JSON-LD/breadcrumb. _prefix per CLAUDE.md convention.
  enum :property_type, { flat: 0, house: 1, commercial: 2, land: 3 },
       prefix: :type

  # _prefix: true → case_study.status_draft?, case_study.status_published?
  # (prefix prepended — это конвенция CLAUDE.md правила #2; suffix gave бы
  # «published_status?», но мы держим единообразие с другими моделями).
  enum :status, { draft: 0, published: 1, archived: 2 },
       prefix: true

  validates :title,    presence: true, length: { minimum: 10, maximum: 200 }
  validates :body,     presence: true
  validates :district, presence: true
  validates :area,        numericality: { greater_than: 0 }, allow_nil: true
  validates :deal_amount, numericality: { greater_than: 0 }, allow_nil: true

  before_save :render_markdown, if: :body_changed?

  default_scope { where(deleted_at: nil) }

  scope :published_only, -> { where(status: statuses[:published]).where.not(published_at: nil).where('published_at <= ?', Time.current) }
  scope :recent,         -> { order(published_at: :desc, created_at: :desc) }
  scope :public_facing,  -> { published_only.recent }
  scope :in_district,    ->(d) { where(district: d) if d.present? }

  # Soft-delete API — matches project convention (deleted_at + default_scope).
  def soft_delete!
    update!(deleted_at: Time.current)
  end

  def restore!
    update!(deleted_at: nil)
  end

  def deleted?
    deleted_at.present?
  end

  # «11 дней» / «3 месяца» — UI-friendly срок сделки для landing meta-блока.
  # Up to 60 days в днях, выше — приближённо в месяцах.
  def deal_duration_human
    return nil if deal_duration_days.blank?
    days = deal_duration_days.to_i
    if days < 60
      "#{days} #{pluralize_ru(days, %w[день дня дней])}"
    else
      months = (days / 30.0).round
      "#{months} #{pluralize_ru(months, %w[месяц месяца месяцев])}"
    end
  end

  # «25 000 000 ₽» — formatted для landing-meta + table cards.
  def deal_amount_human
    return nil if deal_amount.blank?
    "#{deal_amount.to_i.to_s.reverse.gsub(/(\d{3})/, '\1 ').reverse.strip} ₽"
  end

  private

  # Defense-in-depth XSS sanitization — см. Article#render_markdown для
  # rationale. Используем same allow-list (Article::ALLOWED_HTML_TAGS).
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
    raw_html = md.render(body.to_s)
    self.body_html = ActionController::Base.helpers.sanitize(
      raw_html,
      tags: Article::ALLOWED_HTML_TAGS,
      attributes: Article::ALLOWED_HTML_ATTRS
    ).html_safe
  end

  def pluralize_ru(count, forms)
    n = count.abs % 100
    return forms[2] if (11..14).cover?(n)
    case n % 10
    when 1 then forms[0]
    when 2..4 then forms[1]
    else forms[2]
    end
  end
end
