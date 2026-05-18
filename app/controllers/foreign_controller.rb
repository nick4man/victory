# frozen_string_literal: true

# Phase B-MVP: foreign-investor landing на /foreign.
#
# Switches I18n.locale на :en для этого controller'а (en.yml seeded
# с key foreign.*). Не влияет на остальные страницы — locale resets
# per-request.
#
# Inventory: показывает top-N premium-properties с EN labels +
# multi-currency price (через format_price_multi helper).
#
# SEO: <html lang="en"> + meta inLanguage='en' + canonical /foreign.
# Sitemap entry добавляется в SitemapController.
class ForeignController < ApplicationController
  before_action :set_english_locale

  def index
    @premium = Property.on_site
                       .premium
                       .where('price >= ?', 15_000_000)
                       .order(price: :desc)
                       .limit(6)
                       .to_a

    @stats = {
      count_active: Property.on_site.premium.count,
      avg_price:    Property.on_site.premium.average(:price)&.to_i,
      cities:       %w[Ryazan Moscow Saint-Petersburg]
    }

    set_meta_tags(
      title:       t('foreign.meta.title'),
      description: t('foreign.meta.description'),
      canonical:   request.url.split('?').first
    )
  end

  private

  def set_english_locale
    I18n.locale = :en
  end
end
