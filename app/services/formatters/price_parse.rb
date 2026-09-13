# frozen_string_literal: true

module Formatters
  # «5,2 млн» / «5 200 000» / «5.2млн» / 5200000 → BigDecimal или nil.
  # Используется ShowReports::Extractor и /bargain — одна интерпретация цифры голосом и текстом.
  module PriceParse
    module_function

    def call(raw)
      return nil if raw.blank?
      return raw.to_d if raw.is_a?(Numeric)

      s = raw.to_s.downcase.gsub(/\s/, '').tr(',', '.')
      millions = s.include?('млн')
      num = s[/\d+(?:\.\d+)?/]
      return nil if num.nil?

      value = num.to_d
      value *= 1_000_000 if millions
      value.positive? ? value : nil
    end
  end
end
