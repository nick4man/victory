# frozen_string_literal: true

require 'digest'

# work_bot 2/3 — генерирует / обновляет gemini-embedding-001 вектор для
# завершённой PropertyValuation. Skip если content_hash не изменился
# (Google free tier — 100 rpm, лишние вызовы недопустимы).
#
# Triggers:
#   • PropertyValuation after_commit при переходе статуса в completed
#   • Backfill rake task `rake embeddings:valuations` (только completed)
class EmbedPropertyValuationJob < ApplicationJob
  queue_as :low_priority

  retry_on ::Embedding::GoogleClient::Error, wait: :polynomially_longer, attempts: 5

  def perform(property_valuation_id)
    valuation = PropertyValuation.find_by(id: property_valuation_id)
    return unless valuation&.completed? && !valuation.audit_mode_investment?
    # staff_test — тестовые оценки сотрудников: в semantic-поиск похожих
    # для клиентов они не должны попадать (issue #201).
    # test? — probe-прогон чат-бота (issue #214): аналогично вне корпуса.
    return if valuation.staff_test? || valuation.test?

    text = ::Embedding::PropertyValuationTextTemplate.build(valuation)
    return if text.blank?

    hash = Digest::SHA256.hexdigest(text)

    record = PropertyValuationEmbedding.find_or_initialize_by(property_valuation_id: valuation.id)
    if record.persisted? && record.content_hash == hash
      Rails.logger.debug("[EmbedPropertyValuationJob] valuation=#{valuation.id} unchanged, skip")
      return
    end

    vector = ::Embedding::GoogleClient.new.embed(text)

    record.update!(
      content_hash: hash,
      content_text: text,
      embedding:    vector,
      embedded_at:  Time.current
    )
    # Ошибки записи НЕ проглатываем: retry_on в ApplicationJob обрабатывает
    # GoogleClient::Error, остальное поднимается — синхронный бэкфилл
    # embeddings:valuations учтёт такую строку в failed.
  end
end
