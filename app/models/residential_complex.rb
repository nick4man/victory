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
# Индексация — два РАЗНЫХ правила, и это сознательно:
#   `sitemap_ready?` — что мы предлагаем краулеру обойти: только страницы
#     с собственным редакционным текстом;
#   `indexable?`     — что мы не запрещаем индексировать (noindex-guard
#     Фазы 3): текст ЛИБО живые объекты.
# `sitemap_ready?` строго уже. ЖК без текста, но с объектами в sitemap не
# попадает и при этом не деиндексируется — рекламировать его нечем, а
# выкидывать из индекса, пока есть что показать, незачем. Нулевой же
# остаток объектов у ЖК штатен (продались), и именно тогда страница с
# фактурой обязана ранжироваться — потому indexable? и не завязан на
# инвентарь. Менять эти правила только парой: расхождение между тем, что
# в sitemap, и тем, что отдаёт noindex, Яндекс демотирует.
class ResidentialComplex < ApplicationRecord
  extend FriendlyId
  # `:history` — слаг лежит в БД и редактируем, старые URL обязаны
  # резолвиться (ryazan_districts.rb:16-17 фиксирует слаги как публичный
  # контракт). `:finders` — `.friendly.find` без явного скоупа.
  friendly_id :name, use: %i[slugged history finders]

  # Пре-рендер body_html / body_plain на save. Общий с LandingContent.
  include RendersLandingBlocks

  # Без `dependent:` сознательно. Мягкое удаление идёт через `update!`, а
  # `dependent:` висит на `destroy` — то есть здесь он был бы мёртвым кодом
  # и ложным чувством защиты. Реальную гарантию даёт FK `ON DELETE SET NULL`
  # на уровне БД; при soft-delete привязка намеренно сохраняется (ЖК можно
  # вернуть), а от вьюх удалённый ЖК скрыт `default_scope` — обращение
  # `property.residential_complex` отдаёт nil.
  has_many :properties

  # _prefix per CLAUDE.md convention → complex.housing_class_comfort?
  enum :housing_class, { econom: 0, comfort: 1, business: 2, elite: 3 },
       prefix: true                                    # эконом / комфорт / бизнес / элит

  enum :build_status, { planned: 0, under_construction: 1, completed: 2 },
       prefix: true                                    # проектируется / строится / сдан

  # Города прибиты к реестру намеренно: `Cities.find` при промахе молча
  # фолбэчит на Рязань, поэтому без inclusion любой город вне реестра
  # («Москва г.», «Красногорск», опечатка) проверялся бы против районов
  # Рязани и проходил валидацию.
  CITY_NAMES = Cities::REGISTRY.values.map { |c| c[:name] }.freeze

  validates :name, presence: true, length: { maximum: 120 }
  validates :city, presence: true, inclusion: { in: CITY_NAMES }
  validates :title,            length: { maximum: 200 }, allow_blank: true
  validates :meta_description, length: { maximum: 300 }, allow_blank: true
  validates :built_from, :built_to,
            numericality: { only_integer: true, greater_than: 1900, less_than_or_equal_to: 2100 },
            allow_nil: true
  validate :district_slug_known
  validate :built_range_ordered

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

  # friendly_id hook: слаг генерируется РОВНО ОДИН РАЗ — при создании, если
  # не задан явно. Дальше он меняется только руками через поле формы.
  #
  # Автоматическая ротация на переименовании (даже у неопубликованных)
  # выглядела удобной, но давала два тихих отказа: сид с
  # `find_or_initialize_by(slug:)` переставал находить переименованную
  # запись и на следующем прогоне плодил дубль, а уже расшаренный черновик
  # менял URL под ногами. Для сущности, где слаг И ЕСТЬ продукт, стабильность
  # важнее удобства: старые URL резолвит `history`, смену подстрахует 301.
  def should_generate_new_friendly_id?
    slug.blank?
  end

  def sitemap_ready?
    published? && body_html.present?
  end

  # Пускаем в индекс либо со своим текстом, либо пока есть что показывать.
  def indexable?
    sitemap_ready? || on_site_listings_count.positive?
  end

  # Через ассоциацию, а не `Property.where(residential_complex_id: id)`:
  # у несохранённой записи id нил, и ручной where превратился бы в
  # `IS NULL`, то есть вернул бы все непривязанные объекты каталога —
  # `indexable?` на превью формы отдавал бы true.
  def on_site_listings
    properties.on_site
  end

  def on_site_listings_count
    @on_site_listings_count ||= on_site_listings.count
  end

  # Счётчик мемоизирован — сбрасываем, иначе после привязки объектов
  # в админке тот же объект отдаёт залипшее значение.
  def reload(*)
    @on_site_listings_count = nil
    super
  end

  def display_name
    "ЖК «#{name}»"
  end

  # Человеческое имя района — из реестра СВОЕГО города, не рязанского:
  # у московского ЖК RyazanDistricts.name_for вернул бы nil и в UI
  # показался бы слаг.
  def district_name
    return if district_slug.blank?

    slug = city_slug
    return district_slug if slug.nil?

    mod = Cities.districts_module(slug)
    mod::MICRO.dig(district_slug, :name) || mod::ADMIN.dig(district_slug, :name) || district_slug
  end

  def public_path
    "/zhk/#{slug}"
  end

  def soft_delete!
    update!(deleted_at: Time.current)
  end

  private

  def built_range_ordered
    return if built_from.blank? || built_to.blank? || built_from <= built_to

    errors.add(:built_to, 'не может быть раньше года первой очереди')
  end

  # Битый district_slug тихо ломает перелинковку (ЖК → лендинг района),
  # поэтому валидируем против реестра города, а не полагаемся на редактора.
  def district_slug_known
    return if district_slug.blank?

    slug = city_slug
    # Город вне реестра ловит inclusion на :city — второе сообщение про
    # район было бы шумом и указывало бы не на тот модуль.
    return if slug.nil?

    mod = Cities.districts_module(slug)
    return if mod::MICRO.key?(district_slug) || mod::ADMIN.key?(district_slug)

    errors.add(:district_slug, "неизвестен для города «#{city}» (см. #{mod})")
  end

  # Обратный lookup Cities::REGISTRY: canonical name → URL-slug.
  # nil при промахе — без фолбэка на Рязань, иначе чужой город тихо
  # проверялся бы против рязанских районов.
  def city_slug
    Cities::REGISTRY.find { |_slug, cfg| cfg[:name] == city }&.first
  end
end
