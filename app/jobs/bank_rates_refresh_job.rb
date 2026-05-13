# frozen_string_literal: true

# Weekly cron — scrapes banki.ru aggregator for deposit + mortgage
# program rates and stores the result as a `BankRateSnapshot` row.
#
# `Deposit::ProgramsService.all` prefers the latest OK snapshot when one
# exists for the current week; falls back to the hardcoded constant if
# scraping has failed for too long.
class BankRatesRefreshJob < ApplicationJob
  queue_as :scheduled

  KINDS = %w[deposit].freeze   # mortgage added later — banki.ru/products/hypothec/ has different DOM

  def perform
    KINDS.each do |kind|
      result = BankRates::BankiRuParser.new(kind: kind).call
      snapshot = BankRateSnapshot.create!(
        as_of:       Date.current,
        kind:        kind,
        payload:     result.items,
        source:      'banki.ru',
        items_count: result.items.size,
        status:      result.status,
        error_log:   result.error
      )
      Rails.logger.info("[BankRatesRefreshJob] #{kind}: #{result.status} #{result.items.size} items (snapshot ##{snapshot.id})")
    rescue StandardError => e
      Rails.logger.error("[BankRatesRefreshJob] #{kind} crashed: #{e.class}: #{e.message}")
    end
  end
end
