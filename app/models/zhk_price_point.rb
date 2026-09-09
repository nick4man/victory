# frozen_string_literal: true

# Точка ряда цены за м². Журнал — soft-delete не применяется.
#
# FK на residential_complex без `on_delete:` (NO ACTION), в отличие от
# `properties.residential_complex_id` (`ON DELETE SET NULL`). Осознанно:
# `residential_complex_id` здесь `null: false`, SET NULL невозможен.
# Жёсткое удаление ЖК с непустым ценовым рядом должно упасть по FK, а не
# молча осиротить строки.
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
