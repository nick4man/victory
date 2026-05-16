# frozen_string_literal: true

# Phase 1.6.B — city-aware dispatch для landing pages. Single source
# of truth о соответствии URL-slug → canonical city name → district
# module. Используется LandingsController + sitemap views + JSON-LD
# (geo.region, addressLocality fallbacks).
#
# URL-slug convention (lower-case, latin only): 'ryazan' / 'moskva' /
# 'spb'. Route helpers (`buy_landing_url`, `moskva_buy_landing_url`,
# `spb_buy_district_landing_url`) генерируются Rails routing когда
# параметр `:city` появляется в defaults.
module Cities
  REGISTRY = {
    'ryazan' => {
      name:       'Рязань',                 # canonical для Property.city / JSON-LD addressLocality
      region:     'Рязанская область',      # JSON-LD addressRegion
      iso_region: 'RU-RYA',                 # geo.region meta
      lat:        AgencyInfo::GEO_LAT,       # default coords (agency office)
      lng:        AgencyInfo::GEO_LNG,
      module:     :RyazanDistricts          # symbol — Object.const_get(...) lazy
    },
    'moskva' => {
      name:       'Москва',
      region:     'Москва',                 # город федерального значения
      iso_region: 'RU-MOW',
      lat:        55.7558,
      lng:        37.6173,
      module:     :MoscowDistricts
    },
    'spb' => {
      name:       'Санкт-Петербург',
      region:     'Санкт-Петербург',         # город федерального значения
      iso_region: 'RU-SPE',
      lat:        59.9343,
      lng:        30.3351,
      module:     :SpbDistricts
    }
  }.freeze

  DEFAULT_SLUG = 'ryazan'

  module_function

  # Lookup by URL slug. Returns hash or nil. nil → 404 in controller.
  def find(slug)
    REGISTRY[slug.to_s] || REGISTRY[DEFAULT_SLUG]
  end

  # Canonical city name (for SQL filter `Property.in_city(name)` and
  # JSON-LD addressLocality). Falls back to Рязань when slug unknown.
  def canonical_name(slug)
    find(slug)[:name]
  end

  # Module that holds MICRO/ADMIN constants для данного города.
  # Resolves symbol lazily через const_get so module load order не
  # matters — services autoload by Zeitwerk.
  def districts_module(slug)
    Object.const_get(find(slug)[:module])
  end

  # Returns all configured slugs (for sitemap iteration etc).
  def all_slugs
    REGISTRY.keys
  end
end
