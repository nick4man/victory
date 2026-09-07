# frozen_string_literal: true

# Откуда взято конкретное поле конкретного ЖК. Журнал — soft-delete не
# применяется (см. ZhkObservation).
#
# FK на residential_complex без `on_delete:` (NO ACTION), в отличие от
# `properties.residential_complex_id` (`ON DELETE SET NULL`). Осознанно:
# здесь `residential_complex_id` — `null: false`, поэтому SET NULL
# невозможен. Жёсткое удаление ЖК с непустым журналом фактов должно упасть
# по FK, а не молча осиротить строки.
class ZhkFact < ApplicationRecord
  belongs_to :residential_complex

  validates :field, :source, :observed_at, presence: true
end
