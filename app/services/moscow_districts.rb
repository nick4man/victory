# frozen_string_literal: true

# Phase 1.6.B — Moscow districts placeholder. Same shape as RyazanDistricts
# (MICRO + ADMIN + helpers) чтобы LandingsController мог dispatch'ить
# districts через единый интерфейс через `Cities.districts_for(city_slug)`.
#
# В этом commit'е модуль пустой scaffold — district landings для Москвы
# не активны (route регулярка `[a-z0-9-]+` все ещё ловит slug, но
# DISTRICT_MAP вернёт nil → controller render_not_found). В Phase 1.6.C
# заполним top 12-15 районов: ЦАО (Тверской, Хамовники, Замоскворечье,
# Арбат, Пресненский), ЦАО/ВАО переход, известные новостройки-районы
# (Хорошёвский, Раменки, Беговой).
module MoscowDistricts
  MICRO = {
    # 1.6.C: 'khamovniki' => { name: 'Хамовники', admin: %w[ЦАО], aliases: ['Хамовники'] },
  }.freeze

  ADMIN = {
    # 1.6.C: 'cao' => { name: 'ЦАО', children: %w[khamovniki tverskoy ...], aliases: ['ЦАО'] },
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

  def neighbors_of(_slug)
    []  # 1.6.C: per-admin grouping like RyazanDistricts.neighbors_of
  end
end
