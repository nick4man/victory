# frozen_string_literal: true

require 'net/http'
require 'nokogiri'

# Phase B-MVP: получает курс RUB к USD/EUR/AED для multi-currency
# отображения premium-объектов foreign-investor'ам.
#
# Источник: cbr.ru/scripts/XML_daily.asp (Bank of Russia, бесплатный
# XML feed, обновляется ежедневно ~12:00 МСК). AED не на cbr — derived
# через USD cross-rate (1 USD ≈ 3.6725 AED, peg к доллару).
#
# Cache: 6h. Fallback: hardcoded conservative defaults если cbr unreachable.
# Pattern mirrors MacroRatesService.
#
# Usage:
#   rates = CurrencyRatesService.call
#   # → { usd: 95.5, eur: 103.2, aed: 26.0, source: 'cbr.ru', fetched_at: ... }
#   usd_amount = rub / rates[:usd]
class CurrencyRatesService
  CACHE_KEY = 'currency_rates:v1'
  CACHE_TTL = 6.hours
  CBR_URL = 'https://www.cbr.ru/scripts/XML_daily.asp'

  # AED имеет фиксированный peg к USD (~3.6725 USD = 1 AED).
  # Поэтому если у нас USD/RUB, то AED/RUB = USD_RUB / 3.6725.
  AED_PER_USD = 3.6725

  # Conservative fallback rates если cbr unreachable. Подтверждены
  # 16.05.26. Слегка консервативно — лучше показать чуть выше
  # foreign-currency-equivalent, чем underprice.
  FALLBACK_RATES = {
    usd:    95.0,
    eur:    103.0,
    aed:    25.87,  # = 95.0 / 3.6725
    source: 'fallback',
    stale:  true
  }.freeze

  CURRENCY_CODES = %w[USD EUR].freeze  # AED computed locally

  def self.call
    Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) { fetch }
  rescue StandardError => e
    Rails.logger.warn("[CurrencyRatesService] cache fetch failed: #{e.class}: #{e.message}")
    FALLBACK_RATES.merge(error: e.message)
  end

  def self.bust!
    Rails.cache.delete(CACHE_KEY)
  end

  def self.fetch
    xml = fetch_xml
    if xml.blank?
      Rails.logger.warn('[CurrencyRatesService] xml blank — using FALLBACK rates (cbr.ru unreachable)')
      return FALLBACK_RATES
    end

    # CBR XML declaration: <?xml version="1.0" encoding="windows-1251"?>
    # После наших CP1251→UTF-8 байтов declaration лжёт. Strict parser
    # отказывается («Invalid bytes in character encoding»). Заменяем
    # declaration на UTF-8 ИЛИ роняем strict — оба варианта стабильны.
    xml_utf = xml.sub(/encoding="windows-1251"/i, 'encoding="UTF-8"')
    doc = Nokogiri::XML(xml_utf, &:nonet)
    rates = {}
    CURRENCY_CODES.each do |code|
      node = doc.at_xpath("//Valute[CharCode='#{code}']")
      next unless node

      nominal = node.at_xpath('./Nominal')&.text.to_f
      value = node.at_xpath('./Value')&.text.to_s.tr(',', '.').to_f
      next if nominal.zero? || value.zero?

      rates[code.downcase.to_sym] = (value / nominal).round(4)
    end

    if rates.empty?
      Rails.logger.warn('[CurrencyRatesService] empty rates from cbr — XML parse OK but no Valute nodes — using FALLBACK')
      return FALLBACK_RATES
    end

    rates[:aed] = (rates[:usd] / AED_PER_USD).round(4) if rates[:usd]
    rates[:source] = 'cbr.ru'
    rates[:stale] = false
    rates[:fetched_at] = Time.current.iso8601
    rates
  rescue StandardError => e
    Rails.logger.warn("[CurrencyRatesService] parse failed: #{e.class}: #{e.message}")
    FALLBACK_RATES.merge(error: e.message)
  end

  def self.fetch_xml
    uri = URI(CBR_URL)
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                        open_timeout: 5, read_timeout: 10) do |http|
      req = Net::HTTP::Get.new(uri.request_uri, 'User-Agent' => 'victory62-currency-bot/1.0')
      res = http.request(req)
      # cbr.ru returns Windows-1251 — convert to UTF-8 для Nokogiri::XML strict parse
      res.body.to_s.force_encoding('CP1251').encode('UTF-8', invalid: :replace, undef: :replace)
    end
  rescue StandardError => e
    Rails.logger.warn("[CurrencyRatesService] HTTP fetch failed: #{e.class}: #{e.message}")
    ''
  end
end
