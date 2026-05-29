# frozen_string_literal: true

# Helpers for SEO landing pages (`/kupit/<type>/...`, `/snyat/<type>/...`,
# `/<city>/kupit/<type>/...`). Pure presentation helpers — никакой
# domain logic, она в `LandingsController`.
module LandingsHelper
  # Per-file alt-теги для district-фото в `public/images/landings/<slug>/`.
  # Без этой карты все слайды одного района получают идентичный
  # `@h1` ("Купить квартиру в Центральном районе") — слабый image-SEO
  # сигнал. Каждый отдельный кадр должен описывать что именно показано:
  # объект, улица, ориентир — это контент для Я.Картинки и Google Images.
  #
  # Keys — district slug (matches `RyazanDistricts::MICRO`/`ADMIN`).
  # Inner keys — filename в `public/images/landings/<slug>/`.
  # Если для конкретного файла нет alt — fallback на `@h1` (см. метод
  # `alt_for_district_photo`).
  DISTRICT_PHOTO_ALTS = {
    'centr' => {
      'hero.jpg'        => 'Лыбедский бульвар — жилой комплекс в центре Рязани',
      'vokzal-wide.jpg' => 'Железнодорожный вокзал «Рязань-1» — центр города'
    },
    'moskovskiy-mr' => {
      'hero.jpg'    => 'Новые жилые комплексы вдоль Московского шоссе — Рязань',
      'highway.jpg' => 'Московское шоссе — транспортная артерия Рязани'
    }
  }.freeze

  # Resolve alt-text для конкретного файла фото в районе.
  # @param district_slug [String, nil] — slug района (`@district_slug`)
  # @param filename [String] — basename файла (`p.basename.to_s`)
  # @param fallback [String, nil] — что подставить если в map нет записи
  #   (обычно `@h1` страницы)
  def alt_for_district_photo(district_slug, filename, fallback: nil)
    DISTRICT_PHOTO_ALTS.dig(district_slug, filename) || fallback || ''
  end
end
