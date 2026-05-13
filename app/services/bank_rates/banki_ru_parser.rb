# frozen_string_literal: true

require 'net/http'
require 'nokogiri'
require 'uri'

# Scrapes banki.ru aggregator pages for current deposit / mortgage rates.
# Returns a normalised array of program hashes that the same shape as
# `Deposit::ProgramsService::PROGRAMS`, so callers (the calculator page,
# the investment-audit form) don't care whether the data came from the
# constant or the scraper.
#
# Key design decisions:
#
# 1. **banki.ru sets a JS-challenge cookie on first hit (302 → 200).**
#    We honour the cookie via `Net::HTTP` redirect-with-cookie sequence.
#    No headless browser; raw HTTP works because the rendered HTML
#    includes the deposit cards.
#
# 2. **Robust to layout drift.** The page is React-rendered with stable
#    `data-test="deposit-card--*"` attributes. We walk up from each
#    `*--stat-rate` node to find its card container, then read sibling
#    fields. If banki.ru changes the layout — we return a partial result
#    and log; never crash the caller.
#
# 3. **Graceful degradation.** Network failure / parse failure / fewer
#    than MIN_ITEMS cards → returns nil (caller falls back to the
#    hardcoded `Deposit::ProgramsService::PROGRAMS` constant).
module BankRates
  class BankiRuParser
    DEPOSIT_URL = 'https://www.banki.ru/products/deposits/'
    MORTGAGE_URL = 'https://www.banki.ru/products/hypothec/'
    USER_AGENT   = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

    MIN_ITEMS = 5     # if we got fewer than this, treat the run as failed
    OPEN_TIMEOUT = 8
    READ_TIMEOUT = 25

    KIND_URL = { 'deposit' => DEPOSIT_URL, 'mortgage' => MORTGAGE_URL }.freeze

    Result = Struct.new(:items, :status, :error, keyword_init: true)

    # @param kind [String] 'deposit' or 'mortgage'
    def initialize(kind:)
      raise ArgumentError, "unknown kind=#{kind}" unless KIND_URL.key?(kind)

      @kind = kind
      @url  = KIND_URL[kind]
    end

    def call
      html = fetch_html
      return Result.new(items: [], status: 'failed', error: 'no_html') if html.blank?

      items = parse(html)
      if items.size < MIN_ITEMS
        Result.new(items: items, status: 'partial', error: "only_#{items.size}_items")
      else
        Result.new(items: items, status: 'ok', error: nil)
      end
    rescue StandardError => e
      Rails.logger.warn("[BankiRuParser] #{@kind} failed: #{e.class}: #{e.message.to_s.truncate(200)}")
      Result.new(items: [], status: 'failed', error: "#{e.class}: #{e.message.truncate(160)}")
    end

    private

    # banki.ru responds 302 to itself on first hit and sets `__hash_`
    # cookie. We follow once with the cookie and accept the 200 body.
    def fetch_html
      uri = URI.parse(@url)
      cookies = nil

      2.times do
        req = Net::HTTP::Get.new(uri)
        req['User-Agent'] = USER_AGENT
        req['Accept'] = 'text/html,application/xhtml+xml'
        req['Cookie'] = cookies if cookies

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = READ_TIMEOUT
        response = http.request(req)

        case response
        when Net::HTTPSuccess
          return response.body
        when Net::HTTPRedirection
          cookies = extract_cookies(response['set-cookie']) || cookies
          uri = URI.parse(response['location'])
        else
          Rails.logger.warn("[BankiRuParser] unexpected #{response.code} for #{uri}")
          return nil
        end
      end

      nil
    end

    def extract_cookies(set_cookie_header)
      return nil if set_cookie_header.blank?

      # Single Set-Cookie header from `Net::HTTP` may concatenate multiple
      # cookies with commas. Strip attributes (Path, Max-Age, etc.) and
      # keep only `name=value` pairs.
      set_cookie_header.split(',').filter_map { |s|
        s.strip.split(';').first.presence
      }.join('; ')
    end

    def parse(html)
      doc = Nokogiri::HTML(html)
      rate_nodes = doc.css('[data-test="deposit-card--stat-rate"]')
      return [] if rate_nodes.empty?

      rate_nodes.filter_map { |rate_node| parse_card(rate_node) }.uniq { |i| [i[:bank_name], i[:product_name]] }
    end

    # Card layout has `*--stat-rate` deep inside; walk up to find the
    # enclosing card root (heuristic: 6 parents up). From the card we
    # take the joined text and regex-extract canonical fields. The card
    # text looks like "Свой БанкВклад • Свой вклад с Банки.руСтавка13,55%Срок91 дн.Доход16 891 ₽…".
    def parse_card(rate_node)
      card = rate_node
      6.times { card = card.parent if card.parent }
      text = card.text.gsub(/\s+/, ' ').strip
      return nil if text.blank?

      bank_name = extract_bank_name(card, text)
      product_name = extract_product_name(text)
      rate = extract_rate(rate_node, text)
      term_months = extract_term_months(text)
      return nil if bank_name.blank? || rate.nil? || term_months.nil?

      {
        bank_name: bank_name,
        product_name: product_name,
        rate_max: rate,
        term_months_min: term_months,
        term_months_max: term_months,
        min_amount: 30_000,                # banki.ru aggregator omits min-amount on listing
        capitalization: text.include?('капитал'),
        withdraw_allowed: text.match?(/снят|пополнен/i),
        source_url: extract_card_link(card)
      }
    end

    # Try multiple selectors: official bank-logo alt, then first heading,
    # then the bare prefix before "Вклад"/"Накопительный".
    def extract_bank_name(card, text)
      logo = card.at_css('[data-test="bank-logo"]')
      if logo && (alt = logo['alt'])
        return alt.strip
      end
      heading = card.at_css('a[href*="/bank/"], h2, h3')
      return heading.text.strip if heading && heading.text.strip.present?
      # Bare-text fallback: everything before "Вклад" or "Накопительный"
      text[/\A(.+?)(?:Вклад|Накопительный|Депозит)/, 1]&.strip
    end

    def extract_product_name(text)
      # "...Вклад • Название продуктаСтавка..." — capture between dot/separator and "Ставка"
      text[/(?:Вклад|Накопительный|Депозит)\s*[•·\-]?\s*(.+?)\s*Ставка/, 1]&.strip&.truncate(80) || 'Вклад'
    end

    def extract_rate(rate_node, text)
      # Prefer the dedicated rate node text
      m = rate_node.text.gsub(/\s+/, '').match(/(\d{1,2}[.,]\d{1,2})/)
      m ||= text.match(/Ставка[^0-9]*?(\d{1,2}[.,]\d{1,2})/)
      m ? m[1].tr(',', '.').to_f : nil
    end

    def extract_term_months(text)
      if (m = text.match(/Срок[^0-9]*?(\d+)\s*мес/i))
        return m[1].to_i
      end
      if (m = text.match(/Срок[^0-9]*?(\d+)\s*дн/i))
        # 91 дн → 3 мес (round to nearest month)
        days = m[1].to_i
        return [(days.to_f / 30).round, 1].max
      end
      nil
    end

    def extract_card_link(card)
      a = card.at_css('a[href]')
      href = a && a['href']
      return nil if href.blank?
      href.start_with?('http') ? href : "https://www.banki.ru#{href}"
    end
  end
end
