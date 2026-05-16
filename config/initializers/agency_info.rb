# frozen_string_literal: true

# Single source of truth for АН «Виктори» public-facing contact / location
# data. Used in views (header, footer, contacts, privacy), JSON-LD schema
# blocks, and meta tags. Change values here — they propagate everywhere.
#
# Why a constant module instead of ENV: phones, address and city are
# branding (rarely change, must look identical across pages). API keys
# and verification tokens stay in ENV.
module AgencyInfo
  NAME           = 'АН «Виктори»'
  LEGAL_NAME     = 'АН Виктори'
  TAGLINE        = 'Агентство недвижимости в Рязани и области'

  PHONE_PRIMARY  = '+7 (920) 978-05-08'
  PHONE_BACKUP   = '+7 (910) 617-04-97'
  EMAIL          = 'oks07@yandex.ru'

  ADDRESS_STREET = 'ул. Горького, 86'
  ADDRESS_CITY   = 'Рязань'
  ADDRESS_REGION = 'Рязанская область'
  ADDRESS_ZIP    = '390000'
  GEO_LAT        = 54.6269
  GEO_LNG        = 39.6916

  HOURS_HUMAN    = 'Пн-Пт 9:00-21:00, Сб-Вс 10:00-19:00 (МСК)'
  HOURS_OPEN     = '09:00'
  HOURS_CLOSE    = '21:00'

  WEBSITE_URL    = 'https://victory62.org'

  # E-E-A-T "Experience" signal — Я.Бизнес and Google use foundingDate to
  # weight LocalBusiness rankings against newer competitors. Derived from
  # "18 лет на рынке" wording on the site.
  FOUNDING_DATE  = '2008'

  # Я.Бизнес organisation ID (numeric, 12 digits). Single source of truth
  # для всех Я.Карт integrations: reviews widget (`_yandex_reviews_widget`),
  # SAMEAS_PROFILES (entity graph), hasMap, JSON-LD addresses. Если ID
  # сменится — поменять здесь, все consumers подхватят автоматически.
  YANDEX_ORG_ID  = '180201491739'

  # Primary map card — Я.Карты (after 2GIS migration на основной trust-signal
  # platform for RU SEO). 2GIS остаётся в SAMEAS как secondary entity link.
  MAP_URL        = "https://yandex.ru/maps/org/#{YANDEX_ORG_ID}/"

  # Entity-graph anchors. Каждый URL = node в Schema.org sameAs графе,
  # Я.Поиск использует это для Knowledge Panel + disambiguation entity.
  # Telegram-канал — primary channel для market reports, news digests
  # (см. Article::TELEGRAM_FALLBACK_URL).
  SAMEAS_PROFILES = [
    "https://yandex.ru/maps/org/#{YANDEX_ORG_ID}/",
    'https://2gis.ru/ryazan/firm/6192977768694394',
    'https://t.me/rznvictory'
    # add VK / YouTube / Дзен as they're created
  ].freeze

  # Оператор персональных данных по 152-ФЗ §18.1. Reads из ENV для гибкости
  # (можно подменить в продовой .env без пересборки контейнера), с TODO-
  # fallback'ами для разработки. Используется в app/views/pages/privacy.html.erb.
  # Заполнить через `.env`:
  #   OPERATOR_NAME=Иванов Иван Иванович
  #   OPERATOR_INN=123456789012
  #   OPERATOR_OGRNIP=123456789012345
  #   OPERATOR_LEGAL_ADDRESS=Рязанская обл., г. Рязань, ул. ..., д. ..., кв. ...
  #   OPERATOR_RKN_NUMBER=12-34-567890     # (опционально, после регистрации в реестре РКН)
  OPERATOR_FORM           = 'Индивидуальный предприниматель'
  OPERATOR_NAME           = ENV.fetch('OPERATOR_NAME',          'TODO_FILL_FIO')
  OPERATOR_INN            = ENV.fetch('OPERATOR_INN',           'TODO_FILL_INN')
  OPERATOR_OGRNIP         = ENV.fetch('OPERATOR_OGRNIP',        'TODO_FILL_OGRNIP')
  OPERATOR_LEGAL_ADDRESS  = ENV.fetch('OPERATOR_LEGAL_ADDRESS', 'TODO_FILL_LEGAL_ADDR')
  OPERATOR_RKN_NUMBER     = ENV.fetch('OPERATOR_RKN_NUMBER',    nil)
  OPERATOR_PRIVACY_UPDATED = Date.new(2026, 5, 14)
  OPERATOR_TERMS_UPDATED   = Date.new(2026, 5, 14)

  if defined?(Rails) && OPERATOR_INN.to_s.start_with?('TODO_')
    Rails.logger.warn '[AgencyInfo] OPERATOR_* placeholders not filled — /privacy will display TODO markers. ' \
                      'Set OPERATOR_NAME, OPERATOR_INN, OPERATOR_OGRNIP, OPERATOR_LEGAL_ADDRESS in .env.'
  end

  module_function

  def full_address
    "#{ADDRESS_CITY}, #{ADDRESS_STREET}"
  end

  def postal_address_full
    "#{ADDRESS_ZIP}, #{ADDRESS_REGION}, г. #{ADDRESS_CITY}, #{ADDRESS_STREET}"
  end

  def phone_tel(number = PHONE_PRIMARY)
    "tel:+#{number.gsub(/\D/, '')}"
  end
end
