# frozen_string_literal: true

# Helpers для расчёта sitemap метаданных (lastmod, changefreq, priority).
# Цель — давать crawler'ам максимально точный signal "когда страница
# реально менялась", чтобы:
# (1) Не тратить crawl budget на pages где ничего не поменялось
# (2) Быстрее переиндексировать те где реально появился new content
module SitemapHelper
  # Реальный `lastmod` для district landing — максимум из трёх источников:
  #   1. mtime ERB-партиала `landings/content/<intent>_<type>_<slug>.html.erb`
  #      (правки копирайта — самый частый источник изменений)
  #   2. max(Property.updated_at) для объектов района (новый листинг или
  #      обновление цены / статуса меняет visible content страницы)
  #   3. updated_at последней `LandingContent` row для slot'a (admin-editable
  #      DB-контент, перекрывает file-backed partial когда published)
  #
  # @param slug    [String]   — slug района (`@district_slug` в landings#show)
  # @param aliases [Array<String>] — SQL-aliases района (`RyazanDistricts::MICRO[slug][:aliases]`
  #                                   или ADMIN children flatten)
  # @param intent  [String]   — 'sale' | 'rent', default 'sale'
  # @param type    [String]   — 'kvartira' | 'dom' | ..., default 'kvartira'
  # @return [String] — ISO8601 дата для `<lastmod>` в sitemap
  def district_lastmod(slug, aliases, intent: 'sale', type: 'kvartira')
    candidates = []

    # 1. Mtime файла-партиала
    content_path = Rails.root.join("app/views/landings/content/_#{intent}_#{type}_#{slug}.html.erb")
    candidates << content_path.mtime if content_path.exist?

    # 2. max(Property.updated_at) для района
    if aliases.is_a?(Array) && aliases.any?
      prop_max = Property.on_site.where(district: aliases).maximum(:updated_at)
      candidates << prop_max if prop_max
    end

    # 3. LandingContent (если published row для этого slot'а существует)
    if defined?(LandingContent)
      lc_max = LandingContent
                 .for_landing(intent: intent, type: type, district_slug: slug, rooms: nil)
                 .published
                 .maximum(:updated_at)
      candidates << lc_max if lc_max
    end

    (candidates.compact.max || Time.current).iso8601
  end

  # Аналогично для type-only landing (`/kupit/kvartira` без района) — без
  # district filter, берём весь catalog scope этого type.
  def type_landing_lastmod(intent: 'sale', type: 'kvartira')
    candidates = []
    pt = PropertyType.find_by(slug: type) if defined?(PropertyType)
    if pt
      deal_type = (intent == 'rent' ? :rent : :sale)
      prop_max = Property.on_site.where(deal_type: deal_type, property_type_id: pt.id)
                         .maximum(:updated_at)
      candidates << prop_max if prop_max
    end
    (candidates.compact.max || Time.current).iso8601
  end
end
