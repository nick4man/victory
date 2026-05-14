# frozen_string_literal: true

# Async wrapper around Seo::PropertyMetaGenerator.
#
# Enqueued by:
#   • backfill rake task (mass) — see lib/tasks/seo_generation.rake
#   • after_publish callback (single) — Property#publish! hook
#   • admin manual trigger from Admin::PropertiesController#regen_seo
#
# Idempotent: re-running on a property with fresh seo_generated_at simply
# overwrites the cached copy. The free-first chain costs ≈ 0 most of the
# time (free providers absorb 90%+ of traffic).
module Seo
  class GeneratePropertyMetaJob < ApplicationJob
    queue_as :low_priority

    discard_on ActiveJob::DeserializationError
    retry_on Llm::OmniClient::Error, wait: :polynomially_longer, attempts: 3

    def perform(property_id)
      property = Property.unscoped.find_by(id: property_id)
      return unless property
      return if property.deleted_at.present?

      result = Seo::PropertyMetaGenerator.new(property).persist!

      if result.ok?
        Rails.logger.info(
          "[Seo::GeneratePropertyMetaJob] ok property=#{property.id} model=#{result.model}"
        )
      else
        Rails.logger.warn(
          "[Seo::GeneratePropertyMetaJob] fail property=#{property.id} error=#{result.error}"
        )
      end
    end
  end
end
