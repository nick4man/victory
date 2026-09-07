# frozen_string_literal: true

# Откуда взято конкретное поле конкретного ЖК. Журнал — soft-delete не
# применяется (см. ZhkObservation).
class ZhkFact < ApplicationRecord
  belongs_to :residential_complex

  validates :field, :source, :observed_at, presence: true
end
