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

  # 2GIS organisation card URL — exposed as hasMap on the RealEstateAgent
  # JSON-LD so search engines connect the entity to its mapped location.
  MAP_URL        = 'https://2gis.ru/ryazan/firm/6192977768694394'

  SAMEAS_PROFILES = [
    'https://2gis.ru/ryazan/firm/6192977768694394'
    # add VK / Telegram / YouTube / Я.Бизнес as they're created
  ].freeze

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
