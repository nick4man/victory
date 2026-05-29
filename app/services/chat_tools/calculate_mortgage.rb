# frozen_string_literal: true

module ChatTools
  # Quick annuity mortgage calculation for the chat bot. Returns the
  # monthly payment + total + overpayment, plus a pre-filled link to the
  # full /services/mortgage calculator page so the user can iterate
  # visually if they want.
  #
  # This is the lightest of the three financial tools — does NOT touch
  # the audit engine, does NOT enqueue jobs, just runs the formula in
  # process and returns. Tool description carefully splits it from
  # run_investment_audit ("стоит ли покупать", asks for a property) and
  # get_property_details ("какая цена") so the LLM picks the right one.
  module CalculateMortgage
    DEFAULT_TERM = 20
    DEFAULT_RATE_FALLBACK = 16.5

    def self.schema
      {
        type: 'function',
        function: {
          name: 'calculate_mortgage',
          description: <<~DESC.strip,
            Рассчитывает ежемесячный платёж по ипотеке (аннуитет). Возвращает monthly_payment, total_paid, overpayment, loan_amount + ссылку на полный калькулятор с предзаполненными полями.

            Вызывай когда пользователь спрашивает: "какой будет платёж", "сколько в месяц", "потяну ли ипотеку 5 млн", "переплата по ипотеке". Может работать без объекта — нужны только числа.

            Параметр down_payment может быть в рублях (например 1000000) или в процентах от цены (например 20). Логика: если значение ≤ 100 → проценты; иначе → рубли.

            НЕ для вопросов "стоит ли покупать этот объект" — для этого run_investment_audit. НЕ для "сколько стоит" / "опиши" — это get_property_details.
          DESC
          parameters: {
            type: 'object',
            required: %w[price down_payment],
            properties: {
              price:        { type: 'number', description: 'Цена объекта в рублях' },
              down_payment: { type: 'number', description: 'Первый взнос — рубли или процент (≤100 трактуется как %)' },
              term_years:   { type: 'integer', description: "Срок в годах (default #{DEFAULT_TERM})" },
              rate:         { type: 'number',  description: 'Годовая ставка %. Если не указана — берём текущую из MacroRatesService' }
            },
            additionalProperties: false
          }
        }
      }
    end

    def self.call(args = {})
      price = args[:price].to_f
      return error('Нужна цена объекта') unless price.positive?

      dp_raw = args[:down_payment].to_f
      down_payment = dp_raw <= 100 ? (price * dp_raw / 100.0).round : dp_raw.to_i
      down_payment = [[down_payment, 0].max, price.to_i].min
      term_years = (args[:term_years].presence || DEFAULT_TERM).to_i
      term_years = term_years.clamp(1, 30)
      rate = (args[:rate].presence || default_rate).to_f
      rate = rate.clamp(0.1, 50)

      loan = (price - down_payment).round
      monthly = annuity_payment(loan, rate, term_years)
      total   = monthly * term_years * 12
      overpay = total - loan

      url = calculator_url(price.to_i, down_payment, term_years, rate)

      {
        status:          'ok',
        price:           price.to_i,
        down_payment:    down_payment,
        loan_amount:     loan,
        term_years:      term_years,
        rate:            rate.round(2),
        monthly_payment: monthly.round,
        total_paid:      total.round,
        overpayment:     overpay.round,
        calculator_url:  url,
        message: format_message(monthly: monthly, overpay: overpay, term: term_years, rate: rate, url: url)
      }
    end

    def self.default_rate
      MacroRatesService.call[:mortgage_rate] || DEFAULT_RATE_FALLBACK
    rescue StandardError
      DEFAULT_RATE_FALLBACK
    end

    def self.annuity_payment(principal, annual_rate_pct, term_years)
      months = term_years * 12
      r = (annual_rate_pct.to_f / 100.0) / 12.0
      return 0 if months.zero?
      return principal.to_f / months if r.zero?
      principal * (r * ((1 + r)**months)) / ((1 + r)**months - 1)
    end

    def self.calculator_url(price, down, term, rate)
      params = {
        price:        price,
        down_payment: down,
        term_years:   term,
        rate:         rate.round(2)
      }
      "/services/mortgage?#{params.to_query}"
    end

    def self.format_message(monthly:, overpay:, term:, rate:, url:)
      pad = ->(v) { v.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1 ').reverse }
      "Ежемесячный платёж: ~#{pad.call(monthly)} ₽ · " \
      "Переплата за #{term} лет: ~#{pad.call(overpay)} ₽ при ставке #{rate.round(2)}%. " \
      "Полный калькулятор с программами: #{url}"
    end

    def self.error(message)
      { status: 'error', error: 'invalid_args', message: message }
    end
  end
end
