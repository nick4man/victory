# frozen_string_literal: true

# Curated catalog of deposit/savings programs from major Russian banks.
# Lives in code (not the audit-engine bank_offers table) because the list
# is small (8 banks), changes quarterly, and is only used as static
# display content on the mortgage calculator page.
#
# Refresh: edit the PROGRAMS constant and bump AS_OF when the Central
# Bank changes the key rate or when banki.ru's aggregator shifts more
# than a few percent. The scraper in `BankRates::BankiRuParser` (Part 6
# of the merry-honking-kay plan) will eventually replace this constant
# with a DB-backed snapshot.
#
# Numbers reflect publicly-advertised maximum rates at the time of `AS_OF`.
# Actual rates depend on amount, term, capitalisation, and personal-data
# bank conditions; treat as "ballpark for the comparison block on the
# mortgage calculator page".
module Deposit
  class ProgramsService
    AS_OF = Date.new(2025, 3, 31)
    SOURCE = 'Сводка banki.ru + сайты банков (Q1-2025)'

    PROGRAMS = [
      { bank_name: 'Сбер',           product_name: 'Лучший %',         rate_max: 16.0, term_months_min:  1, term_months_max: 36, min_amount:  50_000, capitalization: true,  withdraw_allowed: false, source_url: 'https://www.sberbank.ru/ru/person/contributions' },
      { bank_name: 'ВТБ',            product_name: 'Накопительный',    rate_max: 15.5, term_months_min:  3, term_months_max: 36, min_amount:  30_000, capitalization: true,  withdraw_allowed: true,  source_url: 'https://www.vtb.ru/personal/deposits-investments/' },
      { bank_name: 'Альфа-Банк',     product_name: 'Альфа-Вклад',      rate_max: 17.0, term_months_min:  3, term_months_max: 24, min_amount:  10_000, capitalization: true,  withdraw_allowed: false, source_url: 'https://alfabank.ru/make-money/deposits/' },
      { bank_name: 'Т-Банк',         product_name: 'Накопительный',    rate_max: 16.5, term_months_min:  1, term_months_max: 24, min_amount:       1, capitalization: true,  withdraw_allowed: true,  source_url: 'https://www.tbank.ru/deposit/' },
      { bank_name: 'Газпромбанк',    product_name: 'Перспектива',      rate_max: 16.2, term_months_min:  6, term_months_max: 36, min_amount:  15_000, capitalization: true,  withdraw_allowed: false, source_url: 'https://www.gazprombank.ru/personal/savings/deposits/' },
      { bank_name: 'Россельхозбанк', product_name: 'Доходный',         rate_max: 15.8, term_months_min:  3, term_months_max: 24, min_amount:   3_000, capitalization: true,  withdraw_allowed: false, source_url: 'https://www.rshb.ru/natural/deposit/' },
      { bank_name: 'Совкомбанк',     product_name: 'Максимальный доход', rate_max: 16.8, term_months_min:  3, term_months_max: 18, min_amount:  50_000, capitalization: false, withdraw_allowed: false, source_url: 'https://sovcombank.ru/deposits' },
      { bank_name: 'Банк Дом.РФ',    product_name: 'Надёжный+',        rate_max: 16.0, term_months_min:  3, term_months_max: 24, min_amount:  50_000, capitalization: true,  withdraw_allowed: false, source_url: 'https://domrfbank.ru/deposits/' }
    ].freeze

    # Returns the catalog — prefers the latest OK snapshot scraped by
    # `BankRatesRefreshJob`, falls back to the hardcoded constant if no
    # recent successful snapshot exists. Both shapes carry the same
    # keys, so views/controllers don't care which source supplied the data.
    def self.all
      snapshot = latest_snapshot
      return snapshot if snapshot.present?

      PROGRAMS.map { |p| p.merge(as_of: AS_OF, source: SOURCE) }
    end

    # Returns array of program hashes from the most recent OK snapshot
    # within the last 14 days, or nil if none. Wrapped in rescue so
    # missing model / missing table doesn't break the calculator.
    def self.latest_snapshot
      snap = BankRateSnapshot.latest_ok('deposit')
      return nil unless snap
      return nil if snap.as_of < 14.days.ago.to_date  # stale → prefer constant

      snap.items.map do |item|
        {
          bank_name:        item['bank_name'],
          product_name:     item['product_name'],
          rate_max:         item['rate_max'].to_f,
          term_months_min:  item['term_months_min'].to_i,
          term_months_max:  item['term_months_max'].to_i,
          min_amount:       item['min_amount'].to_i,
          capitalization:   item['capitalization'],
          withdraw_allowed: item['withdraw_allowed'],
          source_url:       item['source_url'],
          as_of:            snap.as_of,
          source:           "#{snap.source} (snapshot ##{snap.id})"
        }
      end
    rescue StandardError => e
      Rails.logger.warn("[Deposit::ProgramsService] snapshot read failed: #{e.class}: #{e.message}")
      nil
    end

    # Lookup by composite key — used by the investment audit form when
    # the user picks a specific deposit program in the dropdown.
    def self.find(bank_name:, product_name:)
      all.find { |p| p[:bank_name] == bank_name && p[:product_name] == product_name }
    end

    # Stable id derived from bank+product (used as <option value> in
    # select dropdowns). Sanitised so we can put it in URLs / form params.
    def self.id_for(program)
      "#{program[:bank_name]}|#{program[:product_name]}".downcase.gsub(/\s+/, '-')
    end

    def self.find_by_id(id)
      all.find { |p| id_for(p) == id.to_s }
    end
  end
end
