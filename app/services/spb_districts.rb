# frozen_string_literal: true

# Phase 1.6.C — Saint Petersburg districts. SPb administrative structure
# отличается от Москвы: 18 районов на одном уровне (нет округов-родителей
# как ЦАО/ЗАО). Для neighbors_of cross-linking группируем по
# географической доле (центр/север/юг/запад/восток) — это не official
# admin grouping, но даёт sensible URL graph для PageRank distribution.
#
# Slug convention: ASCII-latin lower-case dash. Aliases — что ожидаем в
# Property.district колонке. Текущий SPb catalog (4 listings) district
# не заполнен — landings вернут empty + noindex,follow guard.
#
# Подбор 10 районов — by wordstat «купить квартиру СПб <район>» +
# crucial premium hubs (Петроградский, Адмиралтейский, Центральный).
module SpbDistricts
  MICRO = {
    'tsentralnyy' => {
      name: 'Центральный',
      admin: %w[Центр],
      aliases: ['Центральный', 'Центральный район']
    },
    'admiralteyskiy' => {
      name: 'Адмиралтейский',
      admin: %w[Центр],
      aliases: ['Адмиралтейский', 'Адмиралтейский район']
    },
    'petrogradskiy' => {
      name: 'Петроградский',
      admin: %w[Центр],
      aliases: ['Петроградский', 'Петроградская сторона']
    },
    'vasileostrovskiy' => {
      name: 'Васильевский',
      admin: %w[Запад],
      aliases: ['Васильевский остров', 'Василеостровский район']
    },
    'nevskiy' => {
      name: 'Невский',
      admin: %w[Восток],
      aliases: ['Невский', 'Невский район']
    },
    'frunzenskiy' => {
      name: 'Фрунзенский',
      admin: %w[Восток],
      aliases: ['Фрунзенский', 'Фрунзенский район']
    },
    'kalininskiy' => {
      name: 'Калининский',
      admin: %w[Север],
      aliases: ['Калининский', 'Калининский район']
    },
    'primorskiy' => {
      name: 'Приморский',
      admin: %w[Север],
      aliases: ['Приморский', 'Приморский район']
    },
    'vyborgskiy' => {
      name: 'Выборгский',
      admin: %w[Север],
      aliases: ['Выборгский', 'Выборгский район']
    },
    'moskovskiy' => {
      name: 'Московский',
      admin: %w[Юг],
      aliases: ['Московский', 'Московский район']
    }
  }.freeze

  # Geo-grouping (NOT official admin structure — SPb districts административно
  # на одном уровне). Используется для neighbors_of cross-linking.
  ADMIN = {
    'tsentr' => {
      name: 'Центр',
      children: %w[tsentralnyy admiralteyskiy petrogradskiy],
      aliases: ['Центр Санкт-Петербурга']
    },
    'sever' => {
      name: 'Север',
      children: %w[kalininskiy primorskiy vyborgskiy],
      aliases: ['Северные районы']
    },
    'vostok' => {
      name: 'Восток',
      children: %w[nevskiy frunzenskiy],
      aliases: ['Восточные районы']
    },
    'zapad' => {
      name: 'Запад',
      children: %w[vasileostrovskiy],
      aliases: ['Западные районы']
    },
    'yug' => {
      name: 'Юг',
      children: %w[moskovskiy],
      aliases: ['Южные районы']
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
