# frozen_string_literal: true

module Valuations
  # Общий форматтер рублёвых сумм «1 234 567 ₽».
  #
  # Один источник правила: раньше fmt_rub дублировался в
  # Telegram::WorkBot::LeadAnnouncer и ExpressReportNotifier (и почти
  # добавился третьим дублем в ChatTools::RequestSpecialistEvaluation) —
  # правило отображения валюты не должно разъезжаться по call-site'ам.
  module PriceFormatter
    module_function

    def format_rub(amount)
      return '—' if amount.blank?

      "#{amount.to_i.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1 ').reverse} ₽"
    end
  end
end
