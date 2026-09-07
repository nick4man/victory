# frozen_string_literal: true

# Сырьё от службы сбора (services/zhk-registry). Soft-delete здесь
# намеренно НЕ применяется вопреки общему правилу: это журнал, а не
# доменная сущность — пользователь его не удаляет, а default_scope мешал бы
# аудиту.
class ZhkObservation < ApplicationRecord
  validates :source, :external_id, :fetched_at, :digest, presence: true

  scope :for_source, ->(source) { where(source: source) }
end
