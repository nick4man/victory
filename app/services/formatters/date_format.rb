# frozen_string_literal: true

module Formatters
  # Единый европейский формат дат для всего проекта: dd.MM.yy.
  # Используется в TG-сообщениях бота, нотах в Topnlab, парсинге команд агентов.
  # ВНЕ Rails view-контекста — `Formatters::DateFormat.fmt(date)`.
  # Внутри view — хелпер `fmt_date` (см. DateFormatHelper).
  module DateFormat
    DATE_PATTERN     = '%d.%m.%y'
    DATETIME_PATTERN = '%d.%m.%y %H:%M'
    # Парсинг от агентов: 13.05.26 | 13.5.26 | 13.05.2026 | 13.5
    INPUT_REGEX = /\A(\d{1,2})\.(\d{1,2})(?:\.(\d{2,4}))?\z/

    module_function

    def fmt(value)
      return '' if value.blank?
      to_date(value).strftime(DATE_PATTERN)
    rescue ArgumentError, TypeError
      ''
    end

    def fmt_dt(value)
      return '' if value.blank?
      to_time(value).strftime(DATETIME_PATTERN)
    rescue ArgumentError, TypeError
      ''
    end

    # Парсит ввод агента в `/task 15.05.26 показ` → Date или nil.
    def parse(input)
      return nil if input.blank?
      m = input.to_s.strip.match(INPUT_REGEX)
      return nil unless m
      day, month, year_raw = m[1].to_i, m[2].to_i, m[3]
      year = if year_raw.nil?
               Date.current.year
             elsif year_raw.length == 2
               2000 + year_raw.to_i
             else
               year_raw.to_i
             end
      Date.new(year, month, day)
    rescue ArgumentError
      nil
    end

    def to_date(v)
      case v
      when Date            then v
      when Time, DateTime  then v.to_date
      when String          then Date.parse(v)
      else                      v.to_date
      end
    end

    def to_time(v)
      v.is_a?(Date) && !v.is_a?(DateTime) ? v.to_time : v.to_time
    end
  end
end
