# frozen_string_literal: true

module Yandex
  # Async wrapper around Yandex::WebmasterRecrawlService. Called from
  # after_commit hooks on Article (and future: Property) when content
  # transitions to public state or material body change occurs.
  #
  # Queue: :low_priority — у Я. quota 150 URLs/день, не критично если
  # пнут через минуту-другую. retry — 3 раза с exponential backoff
  # (на случай 502/503 от Я. в моменты пиковой нагрузки).
  class RecrawlUrlJob < ApplicationJob
    queue_as :low_priority

    discard_on ActiveJob::DeserializationError
    retry_on Faraday::TimeoutError, wait: :polynomially_longer, attempts: 3
    retry_on Faraday::ConnectionFailed, wait: :polynomially_longer, attempts: 3

    def perform(url:)
      return if ENV['YANDEX_WEBMASTER_TOKEN'].to_s.empty?

      result = Yandex::WebmasterRecrawlService.queue(url)
      if result.ok?
        Rails.logger.info("[Yandex::RecrawlUrlJob] queued #{url} task=#{result.task_id} remaining=#{result.remaining_quota}")
      else
        Rails.logger.warn("[Yandex::RecrawlUrlJob] failed #{url} — #{result.error}")
      end
    end
  end
end
