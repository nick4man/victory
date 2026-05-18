# frozen_string_literal: true

# /premium — standalone landing для премиум-сегмента (Phase A1).
# Brand statement page, не SEO district-landing (те живут на
# /buy/:type/premium с modifier=premium). Cross-link друг на друга.
class PremiumController < ApplicationController
  CARDS_LIMIT = 24

  def index
    base = Property.on_site.premium

    @premium_properties = base.recent.limit(CARDS_LIMIT).to_a
    @districts = base.where.not(district: [nil, '']).distinct.pluck(:district).sort
    @stats = {
      count_active: base.count,
      avg_price:    base.average(:price)&.to_i,
      avg_area:     base.average(:area)&.to_f&.round(1),
      min_price:    base.minimum(:price)&.to_i,
      max_price:    base.maximum(:price)&.to_i
    }

    set_meta_tags(
      title:       'Премиум-сегмент недвижимости в Рязани — АН «Виктори»',
      description: 'Премиум-квартиры и дома от 15 млн ₽ в Рязани и области. ' \
                   'Эксклюзивные объекты, индивидуальный подход, конфиденциальность сделки.',
      canonical:   request.url.split('?').first
    )
  end
end
