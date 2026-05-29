# frozen_string_literal: true

# Daily cron — scrapes banki.ru aggregator for deposit + mortgage program
# rates and stores the result as a `BankRateSnapshot` row.
#
# `Deposit::ProgramsService.all` prefers the latest OK snapshot when one
# exists; falls back to the hardcoded PROGRAMS constant if scraping has
# failed for too long.
#
# Mortgage scraping currently DEGRADED: banki.ru/products/hypothec/ has
# different DOM (BankiRuParser selectors target `[data-test="deposit-card--*"]`
# only). Mortgage scrape пытается но возвращает status=failed; snapshot
# row для failed kinds НЕ создаётся — иначе latest_ok lookup был бы
# загрязнён бесполезными записями. Mortgage rates на /services/mortgage
# сейчас приходят из audit-engine (61 program через Mortgage::ProgramsService,
# 6h cache). Чтобы они тоже обновлялись daily — нужно либо расширить
# BankiRuParser selectors под mortgage DOM, либо daily run
# `scripts/seed_bank_offers.py` на audit-engine.
class BankRatesRefreshJob < ApplicationJob
  queue_as :scheduled

  KINDS = %w[deposit mortgage].freeze

  def perform
    summary = []
    KINDS.each do |kind|
      result = BankRates::BankiRuParser.new(kind: kind).call

      # Записываем snapshot только для успешного scrape. Failed status
      # засоряет latest_ok() lookup в Deposit::ProgramsService.
      if result.status == 'ok' && result.items.any?
        snapshot = BankRateSnapshot.create!(
          as_of:       Date.current,
          kind:        kind,
          payload:     result.items,
          source:      'banki.ru',
          items_count: result.items.size,
          status:      result.status,
          error_log:   result.error
        )
        summary << "#{kind}: OK #{result.items.size} items (##{snapshot.id})"
        Rails.logger.info("[BankRatesRefreshJob] #{kind}: ok #{result.items.size} items (snapshot ##{snapshot.id})")
      else
        # Mortgage сейчас тут — DOM selectors не extends. Log без snapshot.
        summary << "#{kind}: failed (#{result.error || 'no_items'})"
        Rails.logger.warn("[BankRatesRefreshJob] #{kind}: failed — status=#{result.status} error=#{result.error.to_s.truncate(120)}")
      end
    rescue StandardError => e
      summary << "#{kind}: crashed (#{e.class})"
      Rails.logger.error("[BankRatesRefreshJob] #{kind} crashed: #{e.class}: #{e.message}")
    end
    Rails.logger.info("[BankRatesRefreshJob] summary: #{summary.join(' | ')}")
  end
end
