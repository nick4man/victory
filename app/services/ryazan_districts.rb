# frozen_string_literal: true

# Single source of truth for Ryazan district geography. Used by:
#   - LandingsController     — slug → property filter aliases
#   - _site_header partial   — Каталог mega-menu (chips)
#   - properties/index       — district chips above the listing
#   - sitemap_controller     — generates URLs for every district landing
#   - footer                 — «Районы Рязани» column
#
# Two-level hierarchy:
#   - MICRO (народные названия) — primary user-facing URL,
#     20 unique micro-districts. Some (Кальное) span two ADMIN parents.
#   - ADMIN (юридические) — 4 administrative districts; each has a list of
#     child micro-slugs to render on its landing page.
#
# Slug values are stable — they form public URLs. Adding/renaming a slug
# is a 301-redirect concern, not just a label update.
module RyazanDistricts
  MICRO = {
    # === Московский админ-район (7 микрорайонов) ===
    'kanishchevo'   => { name: 'Канищево',           admin: %w[Московский], aliases: ['Канищево'] },
    'priokskiy'     => { name: 'Приокский',          admin: %w[Московский], aliases: ['Приокский'] },
    'ptitsevod'     => { name: 'пос. Птицевод',      admin: %w[Московский], aliases: ['пос. Птицевод', 'Птицевод'] },
    'nedostoevo'    => { name: 'Недостоево',         admin: %w[Московский], aliases: ['Недостоево'] },
    'semchino'      => { name: 'Семчино',            admin: %w[Московский], aliases: ['Семчино'] },
    'moskovskiy-mr' => { name: 'Московское шоссе',   admin: %w[Московский], aliases: ['Московский', 'Московский (народный)', 'Московское шоссе'] },
    'dyagilevo'     => { name: 'Дягилево',           admin: %w[Московский], aliases: ['Дягилево'] },

    # === Железнодорожный (4) ===
    'gorroshcha'    => { name: 'Горроща',            admin: %w[Железнодорожный], aliases: ['Горроща'] },
    'golenchino'    => { name: 'Голенчино',          admin: %w[Железнодорожный], aliases: ['Голенчино'] },
    'yuzhnyy'       => { name: 'Южный',              admin: %w[Железнодорожный], aliases: ['Южный'] },
    'dashki-voennye' => { name: 'Дашки Военные',     admin: %w[Железнодорожный], aliases: ['Дашки Военные', 'Дашки-Военные'] },

    # === Советский (4, Кальное shared) ===
    'centr'         => { name: 'Центр',              admin: %w[Советский], aliases: ['Центр', 'Центральный'] },
    'borki'         => { name: 'Борки',              admin: %w[Советский], aliases: ['Борки'] },
    'solotcha'      => { name: 'Солотча',            admin: %w[Советский], aliases: ['Солотча', 'Лысая Гора'] },

    # Кальное — единственный микрорайон, который Рязанская градостроительная
    # граница рассекает между Советским и Октябрьским. Один canonical URL,
    # обе админ-страницы перечисляют его в своих children.
    'kalnoe'        => { name: 'Кальное',            admin: %w[Советский Октябрьский], aliases: ['Кальное'] },

    # === Октябрьский (6, включая Кальное) ===
    'dashkovo-pesochnya' => { name: 'Дашково-Песочня', admin: %w[Октябрьский], aliases: ['Дашково-Песочня', 'ДП', 'Песочня'] },
    'nikulichi'     => { name: 'Никуличи',           admin: %w[Октябрьский], aliases: ['Никуличи'] },
    'shlakovyy'     => { name: 'Шлаковый',           admin: %w[Октябрьский], aliases: ['Шлаковый'] },
    'sokolovka'     => { name: 'Соколовка',          admin: %w[Октябрьский], aliases: ['Соколовка'] },
    'dyadkovo'      => { name: 'Дядьково',           admin: %w[Октябрьский], aliases: ['Дядьково'] }
  }.freeze

  ADMIN = {
    'sovetskiy' => {
      name: 'Советский',
      children: %w[centr borki solotcha kalnoe],
      aliases: ['Советский']
    },
    'oktyabrskiy' => {
      name: 'Октябрьский',
      children: %w[dashkovo-pesochnya nikulichi kalnoe shlakovyy sokolovka dyadkovo],
      aliases: ['Октябрьский']
    },
    'zheleznodorozhnyy' => {
      name: 'Железнодорожный',
      children: %w[gorroshcha golenchino yuzhnyy dashki-voennye],
      aliases: ['Железнодорожный']
    },
    'moskovskiy' => {
      name: 'Московский',
      children: %w[kanishchevo priokskiy ptitsevod nedostoevo semchino moskovskiy-mr dyagilevo],
      aliases: ['Московский', 'Московский (народный)']
    }
  }.freeze

  # Slug for «out-of-city» properties — Турлатово, Стенькино, прочие
  # пригороды. Хранится отдельно, не входит ни в один админ-район.
  REGION = {
    'ryazanskaya-oblast' => {
      name: 'Рязанская область',
      aliases: ['Рязанская область', 'Рязанский', 'Турлатово', 'Стенькино']
    }
  }.freeze

  # Returns the array of strings that Property#district can hold for this
  # slug. Caller does `Property.where(district: aliases)`. nil if unknown.
  def self.aliases_for(slug)
    (MICRO[slug] || ADMIN[slug] || REGION[slug])&.[](:aliases)
  end

  def self.name_for(slug)
    (MICRO[slug] || ADMIN[slug] || REGION[slug])&.[](:name)
  end

  # All micro slugs that an admin-district landing should include.
  # Returns the matching aliases (flattened) so SQL `IN` works directly.
  def self.children_aliases(admin_slug)
    admin = ADMIN[admin_slug]
    return [] unless admin

    admin[:children].flat_map { |micro_slug| MICRO[micro_slug][:aliases] }
  end

  # Ordered list of all micro-districts grouped by admin parent — used by
  # the header mega-menu and the catalog chips. Кальное deliberately
  # appears once (under its first admin parent in iteration order).
  def self.micro_grouped_by_admin
    seen = Set.new
    ADMIN.transform_values do |a|
      a[:children].each_with_object([]) do |slug, acc|
        next if seen.include?(slug)
        seen << slug
        acc << [slug, MICRO[slug]]
      end
    end
  end

  def self.all_micro_slugs
    MICRO.keys
  end

  def self.all_admin_slugs
    ADMIN.keys
  end

  # Sibling micro-slugs that share an admin parent with the given micro-slug.
  # Used by landing/show.html.erb to render "Соседние районы" cross-link block.
  # Cross-linking distributes PageRank across the landing pyramid so Yandex
  # can discover all 20 micro landings from any one of them (sitemap + chips
  # alone don't reliably propagate authority).
  #
  # Кальное straddles two admin parents (Советский + Октябрьский) — siblings
  # of both are merged, then capped at 5 entries to keep the chip block tidy.
  def self.neighbors_of(slug)
    micro = MICRO[slug]
    return [] unless micro

    micro[:admin].flat_map do |admin_name|
      admin_slug = ADMIN.find { |_, v| v[:name] == admin_name }&.first
      next [] unless admin_slug

      ADMIN[admin_slug][:children] - [slug]
    end.uniq.first(5)
  end
end
