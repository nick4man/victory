# frozen_string_literal: true

# Хелпер форматирования дат для view: всегда `dd.MM.yy` (см. Formatters::DateFormat).
module DateFormatHelper
  def fmt_date(value)
    Formatters::DateFormat.fmt(value)
  end

  def fmt_datetime(value)
    Formatters::DateFormat.fmt_dt(value)
  end
end
