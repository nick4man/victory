# frozen_string_literal: true

# Phase 1.6.B — Saint Petersburg districts placeholder. Same shape as
# RyazanDistricts. Phase 1.6.C — заполнить топ-12 районов: Центральный,
# Адмиралтейский, Петроградский, Васильевский остров, Невский,
# Калининский, Приморский, Московский, Выборгский, Кронштадтский.
module SpbDistricts
  MICRO = {
    # 1.6.C: 'admiralteyskiy' => { name: 'Адмиралтейский', admin: %w[Центральный], aliases: ['Адмиралтейский'] },
  }.freeze

  ADMIN = {
    # 1.6.C: 'tsentralnyy' => { name: 'Центральный', children: %w[admiralteyskiy ...], aliases: ['Центральный'] },
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
    []
  end
end
