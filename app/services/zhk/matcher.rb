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
      target = normalize(name)
      # Мусорное имя («ЖК .», пустая строка) нормализуется в '' — сравнивать
      # его с чем бы то ни было нельзя: в справочнике теоретически может
      # найтись запись, чьё название тоже схлопывается в '' (валидация
      # `presence: true` смотрит на исходную строку, а не на нормализованную).
      return nil if target.blank?

      # `not_deleted` здесь не снимаем и не дублируем через `unscoped`: без
      # него default_scope и так фильтрует мягко удалённые, но оставляем
      # явно — вызов не должен молча перестать быть безопасным, если
      # default_scope модели когда-нибудь изменится. `.order(:id)` — пул
      # без ORDER BY Postgres не гарантирует порядок; уникального индекса
      # на (city, name) нет, значит дубль с одинаковым нормализованным
      # именем в одном городе — состояние не запрещённое, и без
      # детерминированного порядка матчер «плавал» бы между карточками.
      pool = ResidentialComplex.not_deleted.in_city(city).order(:id).to_a

      by_name = pool.find { |c| normalize(c.name) == target }
      return by_name if by_name

      return nil if address.blank?

      # Адрес нормализуем той же функцией, что и имя — иначе два канала
      # сопоставления живут по разным правилам (пунктуация, ё/е, регистр),
      # и для адреса они будут внезапно мягче, чем для имени.
      normalized_address = normalize(address)

      pool.find do |complex|
        Array(complex.address_patterns).compact_blank.any? do |pattern|
          normalized_pattern = normalize(pattern)
          normalized_pattern.present? && normalized_address.include?(normalized_pattern)
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
