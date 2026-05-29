# frozen_string_literal: true

class Property
  # Async classifier для Property.commercial_type. Триггерится из
  # Property after_save hook когда type=commerce + (commercial_type
  # blank ИЛИ description changed). Idempotent — multiple invocations
  # переписывают только если новое значение validну.
  class ClassifyCommercialTypeJob < ApplicationJob
    queue_as :low_priority

    discard_on ActiveJob::DeserializationError
    retry_on StandardError, wait: :polynomially_longer, attempts: 3

    def perform(property_id)
      property = ::Property.find_by(id: property_id)
      return unless property
      return unless property.property_type&.slug == 'commerce'

      result = ::Property::CommercialTypeClassifier.call(property)
      return if result.blank?

      property.update_columns(commercial_type: result, updated_at: Time.current)
      Rails.logger.info("[ClassifyCommercialTypeJob] property=#{property_id} → #{result}")
    end
  end
end
