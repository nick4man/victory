# frozen_string_literal: true

# Жилой комплекс — entity-страница `/zhk/:slug` под бренд-запросы
# («ЖК Легенда Рязань», «Скобелев купить квартиру»). A2, 08.08.26.
#
# Почему отдельная модель, а не ось в LandingContent: у ЖК нет ни intent,
# ни type — уникальный индекс лендингов (intent, type, district_slug,
# rooms) описывает фасет выдачи, а ЖК это сущность. Редакционный текст
# живёт здесь же в `body_blocks`, механика пре-рендера — общая
# (RendersLandingBlocks).
#
# Источник данных — только ручной ввод через админку. Topnlab название ЖК
# не отдаёт: `@p['building']` в PropertyMapper это номер строения, а
# `is_first_sale` схлопнут в `is_featured`.
#
# Индексация: страница попадает в sitemap и остаётся индексируемой,
# только если у неё есть собственный редакционный текст (`sitemap_ready?`)
# ЛИБО есть живые объекты (`indexable?`). Нулевой остаток объектов —
# штатное состояние (продались), и именно тогда страница с фактурой
# должна ранжироваться. Оба правила — в одном месте, потому что
# расхождение sitemap и robots демотируется Яндексом.
class ResidentialComplex < ApplicationRecord
  extend FriendlyId
  # `:history` — слаг лежит в БД и редактируем, старые URL обязаны
  # резолвиться (ryazan_districts.rb:16-17 фиксирует слаги как публичный
  # контракт). `:finders` — `.friendly.find` без явного скоупа.
  friendly_id :name, use: %i[slugged history finders]

  # Пре-рендер body_html / body_plain на save. Общий с LandingContent.
  include RendersLandingBlocks

  has_many :properties, dependent: :nullify

  # _prefix per CLAUDE.md convention → complex.housing_class_comfort?
  enum :housing_class, { econom: 0, comfort: 1, business: 2, elite: 3 },
       prefix: true                                    # эконом / комфорт / бизнес / элит

  enum :build_status, { planned: 0, under_construction: 1, completed: 2 },
       prefix: true                                    # проектируется / строится / сдан

  validates :name, presence: true, length: { maximum: 120 }
  validates :city, presence: true
  validates :title,            length: { maximum: 200 }, allow_blank: true
  validates :meta_description, length: { maximum: 300 }, allow_blank: true
  validates :built_from, :built_to,
            numericality: { only_integer: true, greater_than: 1900, less_than_or_equal_to: 2100 },
            allow_nil: true
  validate :district_slug_known

  scope :visible,     -> { where(published: true) }
  scope :in_district, ->(slug) { where(district_slug: slug) if slug.present? }
  scope :in_city,     ->(city) { where(city: city) if city.present? }
  # Единственное правило попадания в sitemap: собственный редакционный
  # текст. Наличие объектов НЕ требуется — см. комментарий класса.
  scope :sitemap_ready, -> { visible.where.not(body_html: [nil, '']) }

  # Soft delete (правило #1 CLAUDE.md — без гема paranoia)
  scope :not_deleted, -> { where(deleted_at: nil) }
  scope :deleted,     -> { where.not(deleted_at: nil) }
  default_scope { not_deleted }

  # friendly_id hook: транслитерация до parameterize, иначе кириллица
  # схлопнется в пустой слаг. Общая с Property/Article/CaseStudy карта.
  def normalize_friendly_id(value)
    Property.transliterate_to_latin(value).parameterize
  end

  # friendly_id hook: опубликованному ЖК слаг автоматически не меняем —
  # переименование в админке не должно молча ломать проиндексированный
  # URL. Смена слага — сознательное действие через поле формы (плюс
  # `history` + 301 в контроллере как страховка).
  def should_generate_new_friendly_id?
    slug.blank? || (name_changed? && !published?)
  end

  def sitemap_ready?
    published? && body_html.present?
  end

  # Пускаем в индекс либо со своим текстом, либо пока есть что показывать.
  def indexable?
    sitemap_ready? || on_site_listings_count.positive?
  end

  def on_site_listings
    Property.on_site.where(residential_complex_id: id)
  end

  def on_site_listings_count
    @on_site_listings_count ||= on_site_listings.count
  end

  def display_name
    "ЖК «#{name}»"
  end

  def public_path
    "/zhk/#{slug}"
  end

  def soft_delete!
    update!(deleted_at: Time.current)
  end

  private

  # Битый district_slug тихо ломает перелинковку (ЖК → лендинг района),
  # поэтому валидируем против реестра города, а не полагаемся на редактора.
  def district_slug_known
    return if district_slug.blank?

    mod = Cities.districts_module(city_slug)
    return if mod::MICRO.key?(district_slug) || mod::ADMIN.key?(district_slug)

    errors.add(:district_slug, "неизвестен для города «#{city}» (см. #{mod})")
  end

  # Обратный lookup Cities::REGISTRY: canonical name → URL-slug.
  def city_slug
    Cities::REGISTRY.find { |_slug, cfg| cfg[:name] == city }&.first || Cities::DEFAULT_SLUG
  end
end
