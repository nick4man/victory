# frozen_string_literal: true

# External property listing — comparable data sourced from third-party feeds
# (Yandex Realty YRL XML from other Ryazan agencies, future Avito API, etc.).
# Read-only for the valuation pipeline: never edited by Rails users, only
# refreshed by `ExternalListings::YrlParser` and friends.
class ExternalListing < ApplicationRecord
  # `agency_sitemap` — scraped listings из agency-specific sitemap.xml
  # (см. Valuations::SitemapCompFinder + config/agency_sitemaps.yml).
  # source_id формат: "{agency_key}:{listing_id_or_sha1}", url хранит
  # оригинальный URL listing'а для атрибуции.
  KINDS = %w[yandex_yrl avito cian topnlab_mls agency_sitemap].freeze

  # Per-agency human labels для source: 'agency_sitemap' display.
  # Ключи матчат `agency_key` в config/agency_sitemaps.yml + первый
  # сегмент source_id. Добавляем по мере роста списка партнёров.
  SITEMAP_AGENCY_LABELS = {
    'cian_961'    => 'ЦАН Рязань',
    'novoselye'   => 'Новоселье',
    'agent62'     => 'Агент 62',
    'lr62'        => 'Личный Риэлтор'
  }.freeze

  # Wires `.near([lat,lng], km, units: :km)` for the ComparableFinder's
  # radius-based candidate search. Records arrive pre-geocoded from the
  # source feed; reverse_geocoded_by is the matching declaration.
  reverse_geocoded_by :latitude, :longitude

  validates :source, presence: true, inclusion: { in: KINDS }
  validates :source_id, presence: true, uniqueness: { scope: :source }

  scope :active,    -> { where(closed_at: nil) }
  scope :priced,    -> { where('price > 0') }
  scope :recent,    ->(days = 60) { where('fetched_at > ?', days.days.ago) }
  scope :rooms_eq,  ->(n) { where(rooms: n) }
  scope :rooms_band, ->(n, delta = 1) { where(rooms: ((n - delta)..(n + delta)).to_a) }
  scope :area_band, ->(target, pct = 0.20) { where(area: (target * (1 - pct))..(target * (1 + pct))) }
  scope :for_type,  ->(type) { where(property_type: type) }
  scope :for_deal,  ->(deal) { where(deal_type: deal) }

  # Cheap duck-typing surface so the same code that handles Property / MlsListing
  # can also handle ExternalListing inside ComparableFinder/PriceEstimator.
  def total_area
    area
  end

  def property_condition
    condition
  end

  def display_source
    {
      'yandex_yrl'     => 'Я.Недвижимость',
      'avito'          => 'Avito',
      'cian'           => 'ЦИАН',
      'topnlab_mls'    => 'Topnlab MLS',
      'agency_sitemap' => agency_sitemap_label
    }[source] || source
  end

  # Для source: 'agency_sitemap' — выводим имя агентства из source_id prefix
  # ("cian_961:154500" → "ЦАН"). Fallback на "Партнёрское АН" если префикс
  # не распознан. Mapping в YAML — config/agency_sitemaps.yml ↦ name.
  def agency_sitemap_label
    key = source_id.to_s.split(':', 2).first
    SITEMAP_AGENCY_LABELS[key] || 'Партнёрское АН'
  end

  def price_per_sqm
    return nil if price.to_f.zero? || area.to_f.zero?

    (price.to_f / area.to_f).round
  end
end
