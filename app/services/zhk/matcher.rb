# frozen_string_literal: true

module Zhk
  # Сопоставление находки службы сбора с записью справочника.
  #
  # Сравнение идёт в Ruby, а не в SQL, намеренно: справочник это десятки
  # строк на город, а нормализация («ЖК», кавычки, ё, регистр) в SQL
  # превратилась бы в нечитаемое выражение, которое ещё и индекс не берёт.
  module Matcher
    PREFIX_RX = /\A\s*(жк|жилой\s+комплекс)\s+/i
    JUNK_RX   = /[^[:alnum:]]+/

    module_function

    def call(name:, city:, address: nil)
      pool = ResidentialComplex.unscoped.not_deleted.in_city(city).to_a
      target = normalize(name)

      by_name = pool.find { |c| normalize(c.name) == target }
      return by_name if by_name

      return nil if address.blank?

      pool.find do |complex|
        Array(complex.address_patterns).compact_blank.any? do |pattern|
          address.downcase.include?(pattern.downcase)
        end
      end
    end

    # «ЖК «ЛЕГЕНДА»» и «Легенда» — одно и то же; «Голландия. Парковый
    # квартал» и «Голландия Парковый квартал» — тоже.
    def normalize(value)
      value.to_s.downcase.tr('ё', 'е').sub(PREFIX_RX, '').gsub(JUNK_RX, ' ').strip.squeeze(' ')
    end
  end
end
