# frozen_string_literal: true

# Async wrapper around Seo::IndexNowNotifier. Called from after_commit
# callbacks on Property and Article when they transition to a public state.
module Seo
  class IndexNowNotifyJob < ApplicationJob
    queue_as :low_priority

    discard_on ActiveJob::DeserializationError

    def perform(url:)
      Seo::IndexNowNotifier.new(url).call
    end
  end
end
