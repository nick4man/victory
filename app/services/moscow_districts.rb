# frozen_string_literal: true

# Phase 1.6.C — Moscow districts. Same shape as RyazanDistricts (MICRO +
# ADMIN + helpers) — LandingsController + sitemap + JSON-LD dispatch'ат
# через единый интерфейс `Cities.districts_module('moskva')`.
#
# Slug convention: ASCII-latin, lower-case, dash-separated. Aliases —
# что мы ожидаем увидеть в Property.district колонке (когда Topnlab
# начнёт парсить Moscow district, или ручной admin-tagging). Текущий
# Moscow catalog (8 listings) district колонку не имеет — landings
# вернут empty + noindex,follow guard сработает корректно.
#
# Подбор 12 районов — наиболее частые в запросах «купить квартиру
# Москва <район>» по wordstat-аналитике + premium-сегмент покрытие.
# Hierarchy: ЦАО (7) + ЗАО (2) + СЗАО (1) + ЮАО (1) + ЮЗАО (1).
module MoscowDistricts
  MICRO = {
    # === ЦАО (7 районов — центр + премиум core) ===
    'khamovniki' => {
      name: 'Хамовники',
      admin: %w[ЦАО],
      aliases: ['Хамовники', 'Хамовнический район']
    },
    'tverskoy' => {
      name: 'Тверской',
      admin: %w[ЦАО],
      aliases: ['Тверской', 'Тверской район']
    },
    'presnenskiy' => {
      name: 'Пресненский',
      admin: %w[ЦАО],
      aliases: ['Пресненский', 'Пресня', 'Москва-Сити']
    },
    'zamoskvorechye' => {
      name: 'Замоскворечье',
      admin: %w[ЦАО],
      aliases: ['Замоскворечье']
    },
    'arbat' => {
      name: 'Арбат',
      admin: %w[ЦАО],
      aliases: ['Арбат', 'Арбатский район']
    },
    'yakimanka' => {
      name: 'Якиманка',
      admin: %w[ЦАО],
      aliases: ['Якиманка']
    },
    'basmanniy' => {
      name: 'Басманный',
      admin: %w[ЦАО],
      aliases: ['Басманный', 'Басманный район', 'Чистые пруды']
    },

    # === ЗАО (2 — премиум-кластер) ===
    'ramenki' => {
      name: 'Раменки',
      admin: %w[ЗАО],
      aliases: ['Раменки', 'Воробьёвы горы', 'Минская']
    },
    'dorogomilovo' => {
      name: 'Дорогомилово',
      admin: %w[ЗАО],
      aliases: ['Дорогомилово', 'Парк Победы']
    },

    # === СЗАО (1 — крупный новостройка-район) ===
    'khoroshyovo-mnevniki' => {
      name: 'Хорошёво-Мнёвники',
      admin: %w[СЗАО],
      aliases: ['Хорошёво-Мнёвники', 'Хорошёво', 'Мнёвники']
    },

    # === ЮАО (1 — ЗИЛ / Даниловский редевелопмент) ===
    'danilovskiy' => {
      name: 'Даниловский',
      admin: %w[ЮАО],
      aliases: ['Даниловский', 'ЗИЛ', 'Тульская']
    },

    # === ЮЗАО (1 — Ленинский / премиум-юг) ===
    'gagarinskiy' => {
      name: 'Гагаринский',
      admin: %w[ЮЗАО],
      aliases: ['Гагаринский', 'Ленинский проспект']
    }
  }.freeze

  ADMIN = {
    'cao' => {
      name: 'ЦАО',
      children: %w[khamovniki tverskoy presnenskiy zamoskvorechye arbat yakimanka basmanniy],
      aliases: ['ЦАО', 'Центральный административный округ']
    },
    'zao' => {
      name: 'ЗАО',
      children: %w[ramenki dorogomilovo],
      aliases: ['ЗАО', 'Западный административный округ']
    },
    'szao' => {
      name: 'СЗАО',
      children: %w[khoroshyovo-mnevniki],
      aliases: ['СЗАО', 'Северо-Западный административный округ']
    },
    'yuao' => {
      name: 'ЮАО',
      children: %w[danilovskiy],
      aliases: ['ЮАО', 'Южный административный округ']
    },
    'yuzao' => {
      name: 'ЮЗАО',
      children: %w[gagarinskiy],
      aliases: ['ЮЗАО', 'Юго-Западный административный округ']
    }
  }.freeze

  REGION = {}.freeze

  module_function

  def aliases_for(slug)
    (MICRO[slug] || ADMIN[slug])&.[](:aliases)
  end

  def name_for(slug)
    (MICRO[slug] || ADMIN[slug])&.[](:name)
  end

  def children_aliases(admin_slug)
    admin = ADMIN[admin_slug]
    return [] unless admin

    admin[:children].flat_map { |micro_slug| MICRO[micro_slug][:aliases] }
  end

  def all_micro_slugs
    MICRO.keys
  end

  def all_admin_slugs
    ADMIN.keys
  end

  # Sibling micro-slugs from same admin parent — used by landing-neighbors
  # cross-link partial. Mirror RyazanDistricts.neighbors_of semantics.
  def neighbors_of(slug)
    micro = MICRO[slug]
    return [] unless micro

    micro[:admin].flat_map do |admin_name|
      admin_slug = ADMIN.find { |_, v| v[:name] == admin_name }&.first
      next [] unless admin_slug

      ADMIN[admin_slug][:children] - [slug]
    end.uniq.first(5)
  end
end
