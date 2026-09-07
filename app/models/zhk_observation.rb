# frozen_string_literal: true

# Сырьё от службы сбора (services/zhk-registry). Soft-delete здесь
# намеренно НЕ применяется вопреки общему правилу: это журнал, а не
# доменная сущность — пользователь его не удаляет, а default_scope мешал бы
# аудиту.
class ZhkObservation < ApplicationRecord
  # `optional: true` — привязка не про валидность журнала (пишем даже то,
  # что ни к чему не привязалось), а обратный индекс «какие наблюдения
  # породили эту карточку» и источник `complex_id` для ответа на повторную
  # доставку тем же значением, что и на первую.
  belongs_to :residential_complex, optional: true

  validates :source, :external_id, :fetched_at, :digest, presence: true

  scope :for_source, ->(source) { where(source: source) }
end
