# frozen_string_literal: true

# Точка ряда цены за м². Журнал — soft-delete не применяется.
class ZhkPricePoint < ApplicationRecord
  belongs_to :residential_complex

  # _prefix per CLAUDE.md convention → point.kind_from?
  # from — цена «от» с сайта застройщика; median — медиана по выставленным
  # лотам у агрегатора. Величины разные, сравнивать можно только внутри
  # одного источника И одного kind.
  enum :kind, { from: 0, median: 1 }, prefix: true

  validates :source, :observed_at, :price_per_sqm, presence: true
  validates :price_per_sqm, numericality: { only_integer: true, greater_than: 0 }
end
