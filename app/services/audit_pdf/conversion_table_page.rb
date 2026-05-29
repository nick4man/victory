# frozen_string_literal: true

module AuditPdf
  # B2 — currency conversion reference table. Inserted в EN audit перед
  # GlossaryPage. Содержит ключевые финансовые числа аудита в 6 валютах
  # (RUB / USD / EUR / AED / GBP / CNY) с snapshot курсов на дату аудита.
  #
  # Цель — дать foreign-investor'у full-currency view; settlement
  # происходит в RUB (Russian-licensed bank), но в USD/EUR/AED легче
  # planировать. Snapshot курсов в @rates (PropertyValuation.metadata
  # snapshot если есть, иначе live CurrencyRatesService).
  #
  # AED derived от USD (rate_usd / 3.6725 — pegged dirham).
  # GBP, CNY — extended из @rates если CurrencyRatesService возвращает,
  # иначе fallback на пропорцию USD (для отображения; для real settlement
  # инвестор должен сверить актуальные курсы).
  class ConversionTablePage
    include Theme::Helpers

    # Approximate cross-rates для extended currencies. Используются если
    # @rates содержит только USD/EUR/AED (default CurrencyRatesService).
    # Соотношения от USD на сегодняшний день (rough — для reference only).
    GBP_FROM_USD = 0.79   # 1 USD ≈ 0.79 GBP
    CNY_FROM_USD = 7.20   # 1 USD ≈ 7.20 CNY

    def initialize(doc, valuation, audit, monte_carlo, locale: I18n.locale, rates: nil)
      @doc = doc
      @v = valuation
      @audit = audit || {}
      @mc = monte_carlo || {}
      @locale = locale
      @rates = rates || CurrencyRatesService.call
    end

    def render
      @doc.start_new_page
      paint_paper
      page_header
      rates_summary
      conversion_table
      fx_disclaimer
      page_footer
    end

    private

    def paint_paper
      @doc.canvas do
        @doc.fill_color Theme::PAPER
        @doc.fill_rectangle [0, @doc.bounds.height], @doc.bounds.width, @doc.bounds.height
      end
      @doc.fill_color Theme::INK
    end

    def page_header
      @doc.font(Theme::FONT_FAMILY, style: :bold) do
        @doc.text I18n.t('audit.conversion.page_title').upcase, size: 18
      end
      @doc.move_down 6
      @doc.stroke_color Theme::ACCENT_GOLD
      @doc.line_width 1
      @doc.stroke_horizontal_rule
      @doc.move_down 18
    end

    def rates_summary
      fetched_at = @rates[:fetched_at] || Time.current
      date_str = fetched_at.respond_to?(:strftime) ? fetched_at.strftime('%d %b %Y') : fetched_at.to_s
      source = @rates[:source].to_s.presence || 'cbr.ru'

      @doc.fill_color Theme::MUTED
      @doc.text "#{I18n.t('audit.conversion.rates_as_of')} #{date_str}  ·  #{I18n.t('audit.conversion.rates_source')}: #{source}",
                size: 9
      @doc.fill_color Theme::INK
      @doc.move_down 14
    end

    def conversion_table
      headers = [
        I18n.t('audit.conversion.column_headers.amount_rub'),
        I18n.t('audit.conversion.column_headers.usd'),
        I18n.t('audit.conversion.column_headers.eur'),
        I18n.t('audit.conversion.column_headers.aed'),
        I18n.t('audit.conversion.column_headers.gbp'),
        I18n.t('audit.conversion.column_headers.cny')
      ]

      data_rows = key_amounts.map do |label, rub|
        [
          [label, fmt_rub(rub)].compact.join("\n"),
          fmt_currency(rub, :usd),
          fmt_currency(rub, :eur),
          fmt_currency(rub, :aed),
          fmt_currency(rub, :gbp),
          fmt_currency(rub, :cny)
        ]
      end

      # Каждая строка имеет label на верхней линии (bold) + сумма ниже
      # (regular). Inline'им через newline в первой колонке.
      @doc.table([headers] + data_rows, header: true, width: @doc.bounds.width,
                                        cell_style: { size: 9.5, padding: [9, 9],
                                                      border_color: Theme::HAIRLINE,
                                                      inline_format: true }) do
        row(0).background_color = Theme::INK
        row(0).text_color = 'FFFFFF'
        row(0).font_style = :bold
        row(0).size = 8
        column(0).text_color = Theme::INK_SOFT
        columns(1..5).align = :right
        rows(2..-1).each_with_index do |r, i|
          r.background_color = Theme::TINT if i.odd?
        end
      end
      @doc.move_down 14
    end

    def key_amounts
      result = []
      if (price = @audit['price_total']).present?
        result << [I18n.t('audit.conversion.rows.property_price'), price.to_f]
      end
      if (ppsm = @audit['price_per_sqm']).present?
        result << [I18n.t('audit.conversion.rows.price_per_sqm'), ppsm.to_f]
      end
      if (annual_cf = compute_annual_cashflow).present?
        result << [I18n.t('audit.conversion.rows.annual_cashflow'), annual_cf]
      end
      if (five_yr = compute_five_year_outcome).present?
        result << [I18n.t('audit.conversion.rows.five_year_total'), five_yr]
      end
      result
    end

    # Эвристики для cashflow / 5-year outcome (если engine не вернул напрямую).
    def compute_annual_cashflow
      @audit['annual_cashflow'] || @mc.dig('cash', 'annual_cashflow_median')
    end

    def compute_five_year_outcome
      @audit['five_year_net'] || @mc.dig('cash', 'net_outcome_5y_median')
    end

    # Возвращает форматированную сумму в нужной валюте.
    # USD / EUR / AED — из @rates напрямую; GBP / CNY — из USD кросс-курса
    # если в rates нет (default CurrencyRatesService).
    def fmt_currency(rub, currency)
      return '—' if rub.blank?
      rate = currency_rate(currency)
      return '—' if rate.blank? || rate.zero?

      amount = (rub.to_f / rate).round
      symbol = CURRENCY_SYMBOL[currency]
      "#{symbol}#{amount.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1,').reverse}"
    end

    CURRENCY_SYMBOL = {
      usd: '$', eur: '€', aed: 'AED ', gbp: '£', cny: '¥'
    }.freeze

    def currency_rate(currency)
      direct = @rates[currency]
      return direct.to_f if direct.present?

      # Derive из USD-based cross rate для GBP/CNY если CurrencyRatesService
      # not включает их (default только usd/eur/aed).
      usd_rate = @rates[:usd].to_f
      return nil if usd_rate.zero?

      case currency
      when :gbp then usd_rate / GBP_FROM_USD  # how many RUB per 1 GBP
      when :cny then usd_rate / CNY_FROM_USD  # how many RUB per 1 CNY
      end
    end

    def fx_disclaimer
      explainer(I18n.t('audit.conversion.fx_disclaimer'))
    end

    def page_footer
      @doc.move_cursor_to(40)
      @doc.fill_color Theme::MUTED
      @doc.text I18n.t('audit.page_footer', page: 6, report: @v.report_label),
                size: 7, align: :center
      @doc.fill_color Theme::INK
    end
  end
end
