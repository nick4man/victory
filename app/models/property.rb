# frozen_string_literal: true

# == Schema Information
#
# Table name: properties
#
#  id                   :bigint           not null, primary key
#  title                :string           not null
#  description          :text
#  slug                 :string
#  price                :decimal(15, 2)   not null
#  price_per_sqm        :decimal(10, 2)
#  deal_type            :integer          default("sale"), not null
#  status               :integer          default("draft"), not null
#  user_id              :bigint           not null
#  property_type_id     :bigint
#  area                 :decimal(10, 2)   not null
#  living_area          :decimal(10, 2)
#  kitchen_area         :decimal(10, 2)
#  rooms                :integer
#  bedrooms             :integer
#  bathrooms            :integer
#  floor                :integer
#  total_floors         :integer
#  building_year        :integer
#  building_type        :string
#  condition            :integer          default("normal")
#  address              :string           not null
#  district             :string
#  metro_station        :string
#  metro_distance       :integer
#  metro_transport      :string
#  latitude             :decimal(10, 6)
#  longitude            :decimal(10, 6)
#  views_count          :integer          default(0), not null
#  favorites_count      :integer          default(0), not null
#  inquiries_count      :integer          default(0), not null
#  published_at         :datetime
#  is_featured          :boolean          default(false)
#  deleted_at           :datetime
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#

class Property < ApplicationRecord
  # ============================================
  # EXTENSIONS
  # ============================================
  extend FriendlyId
  # `:history` keeps old slugs resolvable after the canonical one changes —
  # critical because Yandex/Google index slugs and 404s hurt rankings.
  # `:slug_candidates` lets us fall back to district/id when the title alone
  # collides (common: many "1-комн. квартира, 30 м², Рязань, Канищево").
  friendly_id :slug_candidates, use: %i[slugged history finders]

  # GOST 7.79-2000 system B-inspired Cyrillic→Latin map.
  # Chosen because parameterize without locale: strips non-ASCII outright,
  # so titles like "Коммерция, 129.3 м², Москва" produced empty slugs and
  # friendly_id silently fell back to numeric ids.
  CYRILLIC_TO_LATIN = {
    'А' => 'A', 'Б' => 'B', 'В' => 'V', 'Г' => 'G', 'Д' => 'D', 'Е' => 'E', 'Ё' => 'Yo',
    'Ж' => 'Zh', 'З' => 'Z', 'И' => 'I', 'Й' => 'Y', 'К' => 'K', 'Л' => 'L', 'М' => 'M',
    'Н' => 'N', 'О' => 'O', 'П' => 'P', 'Р' => 'R', 'С' => 'S', 'Т' => 'T', 'У' => 'U',
    'Ф' => 'F', 'Х' => 'Kh', 'Ц' => 'Ts', 'Ч' => 'Ch', 'Ш' => 'Sh', 'Щ' => 'Sch',
    'Ъ' => '', 'Ы' => 'Y', 'Ь' => '', 'Э' => 'E', 'Ю' => 'Yu', 'Я' => 'Ya',
    'а' => 'a', 'б' => 'b', 'в' => 'v', 'г' => 'g', 'д' => 'd', 'е' => 'e', 'ё' => 'yo',
    'ж' => 'zh', 'з' => 'z', 'и' => 'i', 'й' => 'y', 'к' => 'k', 'л' => 'l', 'м' => 'm',
    'н' => 'n', 'о' => 'o', 'п' => 'p', 'р' => 'r', 'с' => 's', 'т' => 't', 'у' => 'u',
    'ф' => 'f', 'х' => 'kh', 'ц' => 'ts', 'ч' => 'ch', 'ш' => 'sh', 'щ' => 'sch',
    'ъ' => '', 'ы' => 'y', 'ь' => '', 'э' => 'e', 'ю' => 'yu', 'я' => 'ya'
  }.freeze

  # Pre-pass replacements for tokens that lose meaning when parameterize strips
  # punctuation (`м²` → `m2` not bare `m`, `№` → `no`).
  SLUG_PREPROCESS = {
    'м²' => 'm2', 'М²' => 'm2',
    'м2' => 'm2', 'М2' => 'm2',
    '№'  => 'no'
  }.freeze

  def self.transliterate_to_latin(str)
    pre = str.to_s.dup
    SLUG_PREPROCESS.each { |k, v| pre.gsub!(k, v) }
    pre.each_char.map { |c| CYRILLIC_TO_LATIN.fetch(c, c) }.join
  end

  # friendly_id hook: each candidate is tried in order, first unique wins.
  def slug_candidates
    [
      :title,
      %i[title district],
      %i[title district id]
    ]
  end

  # friendly_id hook: transliterate before the default parameterize so cyrillic
  # survives as latin instead of being stripped to a dash run.
  def normalize_friendly_id(value)
    self.class.transliterate_to_latin(value).parameterize
  end

  # ============================================
  # ASSOCIATIONS
  # ============================================
  belongs_to :user
  belongs_to :property_type, optional: true
  belongs_to :moderated_by, class_name: 'User', optional: true

  # has_many :property_images, dependent: :destroy
  # PropertyImage model is not implemented; Active Storage `images` is used instead.
  has_many :favorites, dependent: :destroy
  has_many :favorited_by_users, through: :favorites, source: :user
  has_many :property_views, dependent: :destroy
  has_many :inquiries, dependent: :destroy
  has_many :viewing_schedules, dependent: :destroy
  has_many :price_histories, dependent: :destroy
  # NOTE: `has_one :virtual_tour` removed — VirtualTour model никогда не
  # существовала (orphan association с initial scaffold, как Inquiry#activities).
  # Виртуальные туры представлены через scalar `virtual_tour_url` column
  # + scope `with_virtual_tour` (line 284). Все callers (home_controller,
  # api/v1/properties_controller) используют именно url, не association.
  has_many :listing_consents, dependent: :destroy
  has_one :active_consent, -> { active.recent },
          class_name: 'ListingConsent'
  has_many :documents, dependent: :destroy
  has_many :notes, as: :notable, dependent: :destroy
  has_one :property_embedding, dependent: :destroy
  # Three responsive sizes × two formats: webp (modern browsers) + jpeg (fallback).
  # resize_to_limit preserves aspect ratio; strip removes EXIF (smaller files,
  # also strips GPS/camera data which we shouldn't leak from agent uploads).
  has_many_attached :images do |attachable|
    attachable.variant :thumb,      resize_to_limit: [400, 300],   saver: { quality: 78, strip: true }
    attachable.variant :thumb_webp, resize_to_limit: [400, 300],   format: :webp, saver: { quality: 75, strip: true }
    attachable.variant :card,       resize_to_limit: [800, 600],   saver: { quality: 82, strip: true }
    attachable.variant :card_webp,  resize_to_limit: [800, 600],   format: :webp, saver: { quality: 80, strip: true }
    attachable.variant :hero,       resize_to_limit: [1920, 1440], saver: { quality: 85, strip: true }
    attachable.variant :hero_webp,  resize_to_limit: [1920, 1440], format: :webp, saver: { quality: 82, strip: true }
  end
  has_many_attached :floor_plans

  ACCEPTABLE_IMAGE_TYPES = %w[image/jpeg image/png image/webp image/gif image/heic image/heif].freeze
  MAX_IMAGE_BYTES = 15.megabytes

  # Reject non-image uploads + размер cap. Если кто-то bypass'ит form и
  # шлёт .exe/.svg/.pdf — отлавливаем на model save (ActiveStorage сам
  # не валидирует content_type). Variants ломаются на не-images, что
  # раньше давало 500 при view render.
  validate :acceptable_image_uploads
  validate :acceptable_floor_plan_uploads

  def acceptable_image_uploads
    return unless images.attached?

    images.each do |img|
      unless ACCEPTABLE_IMAGE_TYPES.include?(img.content_type)
        errors.add(:images, "тип файла недопустим (#{img.content_type})")
      end
      if img.byte_size > MAX_IMAGE_BYTES
        errors.add(:images, "размер #{img.byte_size / 1.megabyte}MB больше лимита #{MAX_IMAGE_BYTES / 1.megabyte}MB")
      end
    end
  end

  def acceptable_floor_plan_uploads
    return unless floor_plans.attached?

    floor_plans.each do |fp|
      allowed = ACCEPTABLE_IMAGE_TYPES + %w[application/pdf]
      unless allowed.include?(fp.content_type)
        errors.add(:floor_plans, "тип файла недопустим (#{fp.content_type})")
      end
    end
  end

  # External CRM identifier (Topnlab); aliased so notes/_crm_notes/notes_sync use crm_id uniformly.
  alias_attribute :crm_id, :external_id

  # ============================================
  # ENUMS
  # ============================================
  enum deal_type: {
    sale: 0,      # Продажа
    rent: 1,      # Аренда
    daily: 2      # Посуточная аренда
  }, _prefix: true

  enum status: {
    draft: 0,             # Черновик
    pending: 1,           # На модерации (admin review)
    active: 2,            # Активен (в рекламе)
    sold: 3,              # Продан
    rented: 4,            # Сдан
    archived: 5,          # Архив
    rejected: 6,          # Отклонен
    pending_consent: 7    # Ожидает подписи клиента (digital agency contract)
  }, _prefix: true

  enum condition: {
    needs_repair: 0,  # Требует ремонта
    normal: 1,        # Обычное состояние
    renovated: 2,     # С ремонтом
    euro: 3,          # Евроремонт
    designer: 4       # Дизайнерский ремонт
  }, _prefix: true

  # ============================================
  # VALIDATIONS
  # ============================================
  validates :title, presence: true, length: { minimum: 10, maximum: 200 }
  validates :description, length: { maximum: 5000 }, allow_blank: true
  validates :price, presence: true, numericality: { greater_than: 0 }
  validates :area, presence: true, numericality: { greater_than: 0 }
  validates :address, presence: true
  validates :deal_type, presence: true
  validates :status, presence: true

  validate :floor_must_be_valid
  validate :areas_must_be_consistent
  validate :published_properties_must_be_complete

  # ============================================
  # CALLBACKS
  # ============================================
  before_validation :normalize_attributes
  before_save :calculate_price_per_sqm
  before_save :sync_geom, if: -> { latitude_changed? || longitude_changed? }
  # Keep `city` column in sync with address — `address_locality` is the
  # canonical parser. Triggers on address change (Topnlab import or
  # admin edit). Avoids re-computing locality at render time and lets
  # SQL filter by city natively (Phase 1.6.B+ city-namespaced routes).
  before_save :sync_city_from_address, if: -> { address_changed? || city.blank? }
  after_create :track_creation
  after_update :track_price_change, if: :saved_change_to_price?
  after_touch :update_search_index
  after_commit :enqueue_embed_if_changed, on: %i[create update]
  after_commit :bust_agency_metrics_cache
  after_commit :notify_indexnow_on_publish, on: %i[create update],
               if: :should_notify_indexnow?

  # ============================================
  # GEOCODING
  # ============================================
  geocoded_by :address
  after_validation :geocode, if: ->(obj) { obj.address.present? && obj.address_changed? }

  # ============================================
  # SEARCH (PgSearch)
  # ============================================
  include PgSearch::Model
  
  pg_search_scope :search_by_text,
    against: {
      title: 'A',
      description: 'B',
      address: 'C',
      district: 'D'
    },
    using: {
      tsearch: {
        prefix: true,
        any_word: true,
        dictionary: 'russian'
      }
    }

  # ============================================
  # SCOPES
  # ============================================
  
  # Status scopes
  # CRM workflow stages (mirrors Topnlab deal_state)
  CRM_LIVE_STATES = %w[lead active ad prepayment deferred].freeze
  # Stages that must NOT appear in the public catalog regardless of ad flags:
  # `deferred` — пауза по инициативе клиента/агента, реклама может быть залипшей
  # `deal/archive/denied` — закрытые/отказные, защита от ручных вставок
  EXCLUDED_FROM_CATALOG = %w[deferred deal archive denied].freeze

  # `published` keeps website-moderated `status: :active`.
  # `in_advertising` is the public-catalog filter — Topnlab tracks two
  # independent ad channels: `in_ad` (own site) and `in_mls` (outbound feed).
  # An object is "in advertising" if it's active in either channel AND not in
  # a paused/closed funnel stage.
  scope :published, -> { where.not(published_at: nil).where(status: :active) }
  # `on_site` — каталог victory62.org. После visibility-decoupling
  # (см. ready_for_site? + ACTIVE_DEAL_STATES) status=:active уже
  # учитывает все условия → alias на published.
  scope :on_site, -> { published }
  # `in_advertising` — outbound feeds (/feeds/yrl.xml, cian.xml, avito.xml).
  # Сохраняет `in_ad OR in_mls` requirement — feeds должны respect
  # agent's outbound-channel choice (платная реклама).
  scope :in_advertising, lambda {
    published
      .where('in_ad = TRUE OR in_mls = TRUE')
      .where('deal_state IS NULL OR deal_state NOT IN (?)', EXCLUDED_FROM_CATALOG)
  }
  scope :crm_live,       -> { published.where(deal_state: CRM_LIVE_STATES) }
  scope :assigned_to,    ->(user) { where(user_id: user.is_a?(User) ? user.id : user) }
  scope :unassigned,     -> { where(user_id: nil) }
  scope :active, -> { where(status: :active) }
  scope :pending_moderation, -> { where(status: :pending) }
  scope :drafts, -> { where(status: :draft) }
  
  # Deal type scopes
  scope :for_sale, -> { where(deal_type: :sale) }
  scope :for_rent, -> { where(deal_type: :rent) }
  scope :for_daily_rent, -> { where(deal_type: :daily) }
  
  # Featured
  scope :featured, -> { where(is_featured: true).order(featured_order: :desc) }

  # Premium segment — Phase A focus. Hybrid definition: price threshold OR
  # explicit marketing override via is_premium boolean. Used by /properties
  # filter, premium landing pyramid (/kupit/:type/premium), property card
  # badge, and admin marking UI. See `.claude/memory/strategicVector.md`.
  PREMIUM_THRESHOLD = 15_000_000
  scope :premium, lambda {
    where('price >= ? OR is_premium = ?', PREMIUM_THRESHOLD, true)
  }
  
  # Sorting
  scope :recent, -> { order(created_at: :desc) }
  scope :by_price_asc, -> { order(price: :asc) }
  scope :by_price_desc, -> { order(price: :desc) }
  scope :by_area_asc, -> { order(area: :asc) }
  scope :by_area_desc, -> { order(area: :desc) }
  scope :by_popularity, -> { order(views_count: :desc, favorites_count: :desc) }
  
  # Filters
  scope :with_virtual_tour, -> { where.not(virtual_tour_url: nil) }
  scope :with_parking, -> { where(has_parking: true) }
  scope :with_balcony, -> { where(has_balcony: true) }
  scope :pets_friendly, -> { where(pets_allowed: true) }
  
  # Price range
  scope :price_between, ->(min, max) { where(price: min..max) if min.present? || max.present? }
  scope :min_price, ->(price) { where('price >= ?', price) if price.present? }
  scope :max_price, ->(price) { where('price <= ?', price) if price.present? }
  
  # Area range
  scope :area_between, ->(min, max) { where(area: min..max) if min.present? || max.present? }
  scope :min_area, ->(area) { where('area >= ?', area) if area.present? }
  scope :max_area, ->(area) { where('area <= ?', area) if area.present? }
  
  # Rooms
  scope :rooms_count, ->(count) { where(rooms: count) if count.present? }
  scope :min_rooms, ->(count) { where('rooms >= ?', count) if count.present? }
  
  # Location
  scope :in_district, ->(district) { where(district: district) if district.present? }
  scope :near_metro, ->(station) { where(metro_station: station) if station.present? }
  # City scope (Phase 1.6) — accepts canonical city name from address_locality:
  # 'Рязань' / 'Москва' / 'Санкт-Петербург' / 'Красногорск' / др.
  # Используется LandingsController когда роут даёт city-param (/moskva/* etc).
  scope :in_city, ->(city) { where(city: city) if city.present? }
  # PostGIS ST_DWithin against geography(Point, 4326). Distance is in meters
  # natively; falls back to lat/lng comparison only if geom is unset.
  scope :within_radius, ->(lat, lng, radius_km) {
    where(
      'geom IS NOT NULL AND ST_DWithin(geom, ST_SetSRID(ST_MakePoint(?, ?), 4326)::geography, ?)',
      lng.to_f, lat.to_f, radius_km.to_f * 1000
    )
  }
  
  # Soft delete
  scope :not_deleted, -> { where(deleted_at: nil) }
  scope :deleted, -> { where.not(deleted_at: nil) }
  
  # Default scope
  default_scope { not_deleted }

  # ============================================
  # RANSACK CONFIGURATION
  # ============================================
  def self.ransackable_attributes(auth_object = nil)
    %w[
      title description price area rooms floor total_floors
      address district metro_station deal_type status condition
      building_year building_type has_parking has_balcony
      pets_allowed latitude longitude created_at is_premium
    ]
  end

  def self.ransackable_associations(auth_object = nil)
    %w[property_type user]
  end

  def self.ransackable_scopes(auth_object = nil)
    %i[published active for_sale for_rent featured premium]
  end

  # ============================================
  # CLASS METHODS
  # ============================================
  
  def self.available
    published.active
  end

  def self.similar_to(property, limit = 4)
    return none unless property
    
    where.not(id: property.id)
      .where(deal_type: property.deal_type)
      .where('price BETWEEN ? AND ?', property.price * 0.8, property.price * 1.2)
      .where('area BETWEEN ? AND ?', property.area * 0.8, property.area * 1.2)
      .published
      .limit(limit)
      .order(Arel.sql('RANDOM()'))
  end

  def self.recommended_for_user(user, limit = 6)
    return featured.limit(limit) unless user

    # Простая рекомендация на основе просмотров и избранного
    viewed_ids = user.property_views.pluck(:property_id).uniq
    favorite_ids = user.favorites.pluck(:property_id).uniq
    
    viewed_properties = where(id: viewed_ids)
    
    if viewed_properties.any?
      avg_price = viewed_properties.average(:price)
      avg_area = viewed_properties.average(:area)
      
      where.not(id: viewed_ids + favorite_ids)
        .where('price BETWEEN ? AND ?', avg_price * 0.7, avg_price * 1.3)
        .where('area BETWEEN ? AND ?', avg_area * 0.7, avg_area * 1.3)
        .published
        .order(views_count: :desc)
        .limit(limit)
    else
      featured.limit(limit)
    end
  end

  # ============================================
  # INSTANCE METHODS
  # ============================================
  
  # Price calculations
  def calculate_price_per_sqm
    self.price_per_sqm = (price / area).round(2) if price.present? && area.present? && area > 0
  end

  def price_formatted
    "#{price.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1 ').reverse} ₽"
  end

  def price_per_sqm_formatted
    return unless price_per_sqm
    "#{price_per_sqm.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1 ').reverse} ₽/м²"
  end

  # ============================================
  # SEO META (cached LLM-generated, with rule-based fallbacks)
  # ============================================
  # See Seo::PropertyMetaGenerator (Phase 2C). Views call effective_*
  # to always get a non-empty string — LLM-generated copy when available
  # (Seo::GeneratePropertyMetaJob populates seo_*), rule-based fallback
  # via the existing generate_meta_{title,description} helpers otherwise.

  def seo_generated?
    seo_generated_at.present?
  end

  def effective_seo_title
    return seo_title if seo_title.present?
    "#{generate_meta_title} — АН «Виктори»".truncate(90, omission: '')
  end

  def effective_seo_description
    return seo_description if seo_description.present?
    generate_meta_description
  end

  def effective_seo_h1
    return seo_h1 if seo_h1.present?
    title.presence || generate_meta_title
  end

  # Stats
  def increment_views!
    increment!(:views_count)
  end

  def increment_phone_views!
    increment!(:phone_views_count)
  end

  # Status checks
  def published?
    status_active? && published_at.present?
  end

  def available?
    published? && !sold? && !rented?
  end

  def sold_or_rented?
    status_sold? || status_rented?
  end

  # Premium-сегмент check — same logic as `Property.premium` scope.
  # Used by _property_card.html.erb badge + admin UI.
  def premium?
    is_premium || price.to_f >= PREMIUM_THRESHOLD
  end

  # Features
  def has_amenities?
    has_parking || has_balcony || has_elevator || has_security
  end

  def metro_walking_distance?
    metro_distance.present? && metro_distance <= 1000
  end

  # Topnlab/MLS sync ингестит `metro` иногда как Array of Hash (структурно:
  # [{id:, station_name:, distance:, color:, is_main:}]). При assign в
  # :string column ActiveRecord cast'ит через .to_s → leak Ruby hash
  # syntax (`[{"station_name"=>"..."}]`) в UI.
  #
  # Этот reader extract'ит human-readable station name из corrupted-string
  # ИЛИ возвращает чистую строку как-есть. Backward-compat для legacy data
  # пока не отработает one-time backfill. View использует этот helper
  # вместо raw #metro_station.
  def metro_station_display
    raw = metro_station.to_s.strip
    return nil if raw.empty?
    return raw unless raw.start_with?('[') || raw.start_with?('{')

    names = raw.scan(/"station_name"\s*=>\s*"([^"]+)"/i).flatten.uniq
    names.first.presence
  end

  # Publishing
  def publish!
    update(
      status: :active,
      published_at: Time.current
    )
  end

  def unpublish!
    update(
      status: :archived,
      published_at: nil
    )
  end

  # Auto-publish gate used by the Topnlab import job (and any manual sync).
  # Four gates, in priority order:
  #   1. deal_state == 'ad'  — CRM business-stage primary signal
  #   2. in_ad == true       — explicit «show on our site» flag
  #   3. images attached     — at least one photo
  #   4. description present — non-blank descriptive text
  # All four must hold. If any fails after a re-import (e.g. agent moves the
  # card off the «ad» stage), the listing auto-archives so it disappears
  # from the catalogue and feeds in the same tick.
  #
  # `update_columns` skips validations and callbacks deliberately: Topnlab
  # payloads often miss "nice to have" fields that Property validates, and
  # we don't want emails / notifiers firing on every CRM sync.
  def publish_if_ready!
    if ready_for_site?
      update_columns(
        status:       Property.statuses[:active],
        published_at: published_at || Time.current,
        updated_at:   Time.current
      )
      true
    else
      if status_active?
        Rails.logger.info(
          "[publish] archiving Property##{id} CRM##{external_id}: " \
          "deal_state=#{deal_state.inspect} in_ad=#{in_ad} " \
          "images=#{images.attached? ? images.attachments.count : 0} " \
          "description_len=#{description.to_s.strip.length}"
        )
        update_columns(
          status:       Property.statuses[:archived],
          published_at: nil,
          updated_at:   Time.current
        )
      end
      false
    end
  end

  # Minimum description length of 30 chars filters out CRM-fallback junk like
  # «.», «—», «нет описания» without rejecting genuinely terse listings.
  MIN_DESCRIPTION_LENGTH = 30

  # Minimum image count that lets a listing pass without a long description.
  # Commercial listings often have an empty `description` in CRM (the sale
  # flow is phone-driven) but carry 30+ photos — that's enough visual
  # context to publish.
  MIN_IMAGES_WITHOUT_DESCRIPTION = 3

  # Visibility decoupling (см. plan «Decouple Site Visibility from
  # Outbound Advertising»). 3 independent concerns:
  #
  #   1. Site visibility (status=:active) ← `ready_for_site?` ниже
  #      Управляется: deal_state lifecycle + content + admin overrides
  #
  #   2. Outbound paid advertising (Avito/Cian) ← `in_ad?`
  #      Управляется агентом в CRM; снимается автоматически когда
  #      кончились деньги на агрегаторе / зависла модерация. НЕ влияет
  #      на site visibility.
  #
  #   3. MLS feed (наш /feeds/yrl.xml/cian.xml/avito.xml) ← `in_mls?`
  #      Управляется агентом отдельно. Influence только outbound feeds
  #      через `in_advertising` scope.
  #
  # `ACTIVE_DEAL_STATES` mirrors importer.rb#ACTIVE_STATES — те же
  # deal_state'ы что мы вообще импортируем (deal/archive/denied
  # filtered на стороне CRM fetch, до нашей DB не доходят).
  ACTIVE_DEAL_STATES = %w[ad active lead prepayment deferred].freeze

  def ready_for_site?
    # Admin explicit hide — highest priority.
    return false if respond_to?(:force_archive) && force_archive

    # Admin explicit show — bypasses gate, для misaligned CRM cases.
    return true if respond_to?(:force_publish) && force_publish

    # Site visibility = deal lifecycle + content quality. `in_ad` НЕ
    # включён здесь — outbound advertising state не должен скрывать
    # объект с нашего сайта (мы модераторы, платить не надо).
    ACTIVE_DEAL_STATES.include?(deal_state.to_s) &&
      images.attached? &&
      ready_content?
  end

  # Either: a non-trivial description, or enough photos to stand on their
  # own. The agent's choice — one of the two has to be there.
  def ready_content?
    description.to_s.strip.length >= MIN_DESCRIPTION_LENGTH ||
      images.attachments.count >= MIN_IMAGES_WITHOUT_DESCRIPTION
  end

  # Human-readable reasons listing isn't on the site (empty array if it is).
  # Used by admin status page to surface "fix this in CRM".
  def publication_blockers
    return ['скрыт администратором (force_archive)'] if respond_to?(:force_archive) && force_archive
    return [] if ready_for_site?

    reasons = []
    unless ACTIVE_DEAL_STATES.include?(deal_state.to_s)
      reasons << "deal_state=#{deal_state.inspect} (нужно: #{ACTIVE_DEAL_STATES.join('/')})"
    end
    reasons << 'нет фото' unless images.attached?
    if images.attached?
      desc_len = description.to_s.strip.length
      img_count = images.attachments.count
      if desc_len < MIN_DESCRIPTION_LENGTH && img_count < MIN_IMAGES_WITHOUT_DESCRIPTION
        reasons << "мало контента (описание #{desc_len} симв., фото #{img_count})"
      end
    end
    reasons
  end

  # Informational: какие outbound channels активны. НЕ влияет на site
  # visibility (см. ready_for_site?). Используется в admin UI badge
  # + cabinet «Мои объекты» для информирования владельца.
  def outbound_advertised?
    in_ad? || in_mls?
  end

  def outbound_status_label
    parts = []
    parts << 'Avito/Cian' if in_ad?
    parts << 'MLS-feed' if in_mls?
    parts.empty? ? 'нет (только сайт)' : parts.join(' + ')
  end

  # Soft delete
  def soft_delete!
    update(deleted_at: Time.current, status: :archived)
  end

  def restore!
    update(deleted_at: nil)
  end

  # Favoriting
  def favorited_by?(user)
    return false unless user
    favorites.exists?(user_id: user.id)
  end

  # Display helpers
  def short_description(length = 150)
    return unless description
    description.truncate(length)
  end

  def full_address
    parts = [address]
    parts << district if district.present?
    parts.join(', ')
  end

  def floor_info
    return unless floor && total_floors
    "#{floor}/#{total_floors} этаж"
  end

  def rooms_info
    return 'Студия' if rooms == 0
    return unless rooms
    
    case rooms
    when 1 then '1-комнатная'
    when 2 then '2-комнатная'
    when 3 then '3-комнатная'
    when 4 then '4-комнатная'
    else "#{rooms}-комнатная"
    end
  end

  def building_age
    return unless building_year
    Time.current.year - building_year
  end

  # Images
  def primary_image
    images.first
  end

  def image_urls
    images.map { |img| Rails.application.routes.url_helpers.rails_blob_url(img, only_path: true) }
  end

  # SEO
  def generate_meta_title
    parts = [rooms_info, deal_type_i18n, area.to_i, 'м²']
    parts << district if district.present?
    parts.compact.join(', ')
  end

  def generate_meta_description
    "#{rooms_info} площадью #{area} м² за #{price_formatted}. #{short_description(100)}"
  end

  # City extracted from the address string — used by JSON-LD addressLocality.
  # The address column stores prefixes like "Москва г.", "Санкт-Петербург г.",
  # "Московская обл., г. Красногорск", "Рязанская обл., г. Рязань, ...".
  # Without this, every property emitted "addressLocality": "Рязань" in
  # Schema.org, which contradicts the address shown on the page for MSK/SPB
  # listings and triggers Google's "conflicting entity data" suppression.
  # Falls back to AgencyInfo::ADDRESS_CITY only when the address is empty.
  def address_locality
    a = address.to_s
    return 'Москва'         if a.include?('Москва г.') || a.match?(/\bг\.\s*Москва\b/)
    return 'Санкт-Петербург' if a.include?('Санкт-Петербург г.') || a.include?('СПб')
    # Match `г. <Name>` — supports hyphenated multi-word names like
    # "Спас-Клепики" (uppercase letter после дефиса). Previous regex
    # `[А-ЯЁ][а-яё-]+` обрывал на втором uppercase, давая "Спас-".
    if (m = a.match(/(?:Московская обл\.[^,]*,\s*)?г\.\s*([А-ЯЁ][а-яё]+(?:-[А-ЯЁ][а-яё]+)*)/))
      return m[1]
    end
    return 'Москва'         if a.include?('Московская обл.')
    return 'Рязань'         if a.include?('Рязанская обл.') || a.include?('Рязань')

    AgencyInfo::ADDRESS_CITY
  end

  # Region (addressRegion) follows the same logic — paired with locality so
  # Schema doesn't say "Рязанская область" for a property in Moscow.
  def address_region
    a = address.to_s
    return 'Москва'              if a.include?('Москва г.') || a.match?(/\bг\.\s*Москва\b/)
    return 'Санкт-Петербург'      if a.include?('Санкт-Петербург г.') || a.include?('СПб')
    return 'Московская область'   if a.include?('Московская обл.')
    return 'Рязанская область'    if a.include?('Рязанская обл.') || a.include?('Рязань')

    AgencyInfo::ADDRESS_REGION
  end

  # Schema.org type for this property — used by both _jsonld_property.html.erb
  # (JSON-LD @type) and properties/show.html.erb (<article itemtype>) so the
  # microdata and JSON-LD never disagree about the entity kind. Disagreement
  # triggers Google Rich Results "conflicting entity types" warnings.
  #
  # `Place` for land/garage was too generic (covers airports, parks etc.) —
  # Schema.org 7.0+ recognises `RealEstateListing` as the proper parent for
  # any listing being sold/rented, including land plots and parking. Google
  # Rich Results understands it; Yandex falls back to base `Place` semantics.
  def schema_org_type
    case property_type&.slug
    when 'house'    then 'House'
    when 'land'     then 'RealEstateListing'
    when 'commerce' then 'CommercialProperty'
    when 'garage'   then 'RealEstateListing'
    else                 'Apartment'
    end
  end

  # Comparison
  def price_difference_percent(other_property)
    return unless other_property && other_property.price > 0
    ((price - other_property.price) / other_property.price * 100).round(2)
  end

  private

  # Callbacks
  def normalize_attributes
    self.title = title.squish if title.present?
    self.address = address.squish if address.present?
    self.district = district.squish if district.present?
  end

  # Derives `city` column из address string using same canonical parser
  # as Property#address_locality (kept inline там for legacy JSON-LD callers).
  # Idempotent — calling multiple times returns same result. Skips when
  # address is blank (rare; validations require address present).
  def sync_city_from_address
    self.city = address_locality
  end

  # Mirror lat/lng into PostGIS geography column via EWKT string literal —
  # Postgres parses 'SRID=4326;POINT(lon lat)' directly into geography, so we
  # don't need the postgis AR adapter or raw SQL casts.
  def sync_geom
    self.geom = if latitude.present? && longitude.present?
                  "SRID=4326;POINT(#{longitude.to_f} #{latitude.to_f})"
                end
  end

  EMBED_TRIGGER_FIELDS = %w[
    title description price area rooms condition
    address district metro_station
    has_balcony has_loggia has_parking has_elevator
  ].freeze

  # Re-embed only when something the embedding template cares about changed.
  # Skips during creation if no description yet (will be re-fired by Topnlab
  # importer at the end of its pipeline).
  def enqueue_embed_if_changed
    return if destroyed?
    return if previous_changes.empty?
    return unless (EMBED_TRIGGER_FIELDS & previous_changes.keys).any? || previous_changes.key?('id')

    EmbedPropertyJob.perform_later(id)
  rescue StandardError => e
    Rails.logger.warn("[Property##{id}] embed enqueue failed: #{e.class} #{e.message}")
  end

  # Sweep agency metrics cache when a property's deal_state crosses 'deal'
  # in either direction (becoming 'deal' = +1 to completed counter,
  # leaving 'deal' = -1). Other writes are skipped.
  def bust_agency_metrics_cache
    return unless previous_changes.key?('deal_state') || previous_changes.key?('price') || destroyed?

    before, after = previous_changes['deal_state'] || [deal_state, deal_state]
    return unless before == 'deal' || after == 'deal' || (deal_state == 'deal' && previous_changes.key?('price'))

    AgencyMetricsService.bust!
  rescue StandardError => e
    Rails.logger.warn("[Property##{id}] metrics cache bust failed: #{e.class} #{e.message}")
  end

  def track_creation
    # Hook for analytics
  end

  def track_price_change
    return unless saved_change_to_price?

    old = price_before_last_save
    new = price
    # Skip если price became nil или 0 (CRM-sync артефакт) — PriceHistory
    # требует new_price > 0 + change_type → invalid record иначе.
    return if new.blank? || new.to_f <= 0
    # Skip если price не изменилась (saved_change_to_price? может срабатывать
    # на null→null edge cases) — PriceHistory validates old != new.
    return if old.present? && old.to_f == new.to_f

    change_type = old.to_f.zero? || old.blank? ? 'increase' : (new > old ? 'increase' : 'decrease')

    price_histories.create(
      old_price: old,
      new_price: new,
      change_type: change_type,
      effective_date: Time.current,
      auto_generated: true,
      reason: 'CRM sync / admin update'
    )

    update_columns(
      price_changed_at: Time.current,
      original_price:   (original_price || old)
    )
  rescue ActiveRecord::RecordInvalid, ActiveModel::UnknownAttributeError => e
    Rails.logger.warn("[Property##{id} track_price_change] #{e.class}: #{e.message}")
  end

  def update_search_index
    # Reindex for search if using external search engine
  end

  # Validations
  def floor_must_be_valid
    return unless floor.present? && total_floors.present?
    
    if floor > total_floors
      errors.add(:floor, 'не может быть больше общего количества этажей')
    end
    
    if floor < 1
      errors.add(:floor, 'должен быть положительным числом')
    end
  end

  def areas_must_be_consistent
    if living_area.present? && living_area > area
      errors.add(:living_area, 'не может быть больше общей площади')
    end
    
    if kitchen_area.present? && kitchen_area > area
      errors.add(:kitchen_area, 'не может быть больше общей площади')
    end
  end

  def published_properties_must_be_complete
    return unless status == 'active' && published_at.present?
    
    errors.add(:base, 'Необходимо добавить хотя бы одно изображение') if images.blank?
    errors.add(:description, 'не может быть пустым для опубликованных объектов') if description.blank?
  end

  # I18n helpers
  def deal_type_i18n
    case deal_type
    when 'sale' then 'продажа'
    when 'rent' then 'аренда'
    when 'daily' then 'посуточно'
    end
  end

  def status_i18n
    I18n.t("activerecord.attributes.property.statuses.#{status}")
  end

  def condition_i18n
    I18n.t("activerecord.attributes.property.conditions.#{condition}")
  end

  private

  # Push IndexNow notification when property becomes (or remains) publicly
  # discoverable. We notify on transition to :active AND on subsequent
  # significant edits while active. Skipped silently if INDEXNOW_API_KEY
  # is unset or we're not in production.
  def should_notify_indexnow?
    return false unless status_active?
    return false if deleted_at.present?

    # On create when published directly into :active, or on update when
    # status just transitioned to :active, or when an active property had
    # its price or title materially changed.
    return true if previously_new_record?
    saved_change_to_status? ||
      saved_change_to_price? ||
      saved_change_to_title?
  end

  def notify_indexnow_on_publish
    url = Rails.application.routes.url_helpers.property_url(
      self,
      host: 'victory62.org',
      protocol: 'https'
    )
    Seo::IndexNowNotifyJob.perform_later(url: url)
  end
end