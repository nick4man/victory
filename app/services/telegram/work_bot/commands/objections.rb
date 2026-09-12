# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # BOTTLENECK — `/objections` reply на карточку или `/objections <lead_id>`:
      # «семь показов, пять раз кухня, четыре раза первый этаж». Это и есть
      # предметный разговор о цене с собственником (Шаг 4, этап 4) — раньше он
      # собирался перечитыванием чата.
      class Objections < Base
        def handle
          lead = resolve_lead!
          return reply(lead_not_found_hint('objections')) unless lead

          property = lead.property
          summary = if property
                      Kpi::ShowFunnel.objections_summary(property: property)
                    else
                      summary_for_lead(lead)
                    end
          title = property ? escape_html(property.address) : "лид ##{lead.id}"
          return reply("🏠 #{title}: показов пока не было.") if summary[:shows].zero?

          reply(render(title, property, summary))
        end

        private

        def summary_for_lead(lead)
          reports = lead.show_reports.status_confirmed.to_a
          { shows: reports.size,
            objections: reports.flat_map(&:objections_list).tally.sort_by { |t, n| [-n, t] },
            outcomes: reports.map(&:outcome).tally,
            offered_prices: reports.filter_map(&:offered_price).map(&:to_i).sort }
        end

        def render(title, property, s)
          lines = ["🏠 <b>#{title}</b> — #{s[:shows]} #{plural(s[:shows])}"]
          lines << "Цена: #{property.price_formatted}" if property
          lines << ''
          lines << '<b>Возражения:</b>'
          lines.concat(s[:objections].first(10).map { |tag, n| "  #{n}× #{escape_html(tag)}" })
          lines << '  — возражений не записано' if s[:objections].empty?
          lines << ''
          lines << "Исходы: #{s[:outcomes].map { |o, n| "#{ShowReport::OUTCOME_LABELS[o]} #{n}" }.join(' · ')}"
          if s[:offered_prices].any?
            prices = s[:offered_prices].map { |p| ActiveSupport::NumberHelper.number_to_delimited(p, delimiter: ' ') }
            lines << "Названные цены: #{prices.join(', ')} ₽"
          end
          lines.join("\n")
        end

        def plural(n)
          return 'показов' if (11..14).cover?(n % 100)
          return 'показ' if n % 10 == 1
          return 'показа' if (2..4).cover?(n % 10)

          'показов'
        end
      end
    end
  end
end
