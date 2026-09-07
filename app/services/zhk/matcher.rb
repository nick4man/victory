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
    # «д.» перед номером дома — не различающий токен, а разделитель, который
    # нормализация как раз и стирает вместе с точкой. Без его удаления
    # паттерн «есенина 1» не находит адрес «есенина, д. 1»: между словами
    # оказывается лишний токен, и границы больше не совпадают.
    ADDRESS_FILLER_TOKENS = %w[д дом].freeze

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

      # Два канала сопоставления сознательно НЕ симметричны по строгости.
      # Имя — полное равенство нормализованных строк: имя ЖК самодостаточно,
      # и наблюдение либо называет его целиком, либо это не совпадение.
      # Адрес — вхождение подстроки с границей токена: наблюдаемый адрес
      # почти всегда шире паттерна (город, квартира, подъезд, лишние слова
      # застройщика), и требовать полного равенства значило бы, что парсер
      # обязан дословно воспроизвести весь адрес — нереалистично.
      normalized_address = normalize_address_tokens(address)

      pool.find do |complex|
        Array(complex.address_patterns).compact_blank.any? do |pattern|
          normalized_pattern = normalize_address_tokens(pattern)
          normalized_pattern.present? && token_boundary_match?(normalized_pattern, normalized_address)
        end
      end
    end

    # «ЖК «ЛЕГЕНДА»» и «Легенда» — одно и то же; «Голландия. Парковый
    # квартал» и «Голландия Парковый квартал» — тоже.
    def normalize(value)
      value.to_s.downcase.tr('ё', 'е').sub(PREFIX_RX, '').gsub(JUNK_RX, ' ').strip.squeeze(' ')
    end

    # Та же нормализация, что и у имени (пунктуация, регистр, ё/е), плюс
    # снятие токенов-заполнителей перед номером дома — см. ADDRESS_FILLER_TOKENS.
    def normalize_address_tokens(value)
      normalize(value).split(' ').reject { |token| ADDRESS_FILLER_TOKENS.include?(token) }.join(' ')
    end

    # Вхождение `pattern` в `text` как последовательности токенов, а не
    # произвольной подстроки: сразу перед и сразу после найденного куска не
    # должно быть буквы/цифры. Обе строки уже нормализованы (единственный
    # пробел между словами), поэтому `\p{Alnum}`-lookaround на границах —
    # самый короткий способ выразить «это отдельные слова, а не обрезок
    # более длинного» без ручного разбора на токены и посимвольного поиска.
    def token_boundary_match?(pattern, text)
      Regexp.new("(?<!\\p{Alnum})#{Regexp.escape(pattern)}(?!\\p{Alnum})").match?(text)
    end
  end
end
