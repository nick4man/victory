# frozen_string_literal: true

module AuditPdf
  # Page 3 — three market scenarios + sensitivity chart.
  # Helps the reader see how the verdict shifts under different macro
  # conditions, especially how mortgage-rate moves affect the EI.
  class ScenariosPage
    include Theme::Helpers

    def initialize(doc, valuation, audit, _monte_carlo)
      @doc = doc
      @v = valuation
      @audit = audit || {}
    end

    def render
      @doc.start_new_page
      paint_paper
      page_header
      scenarios_table
      scenarios_explainer
      sensitivity_section
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
        @doc.text 'СЦЕНАРИИ И ЧУВСТВИТЕЛЬНОСТЬ', size: 18
      end
      @doc.move_down 6
      @doc.stroke_color Theme::ACCENT_GOLD
      @doc.line_width 1
      @doc.stroke_horizontal_rule
      @doc.move_down 18
    end

    def scenarios_table
      scenarios = Array(@audit['scenarios']).compact_blank
      return if scenarios.empty?

      section_label('EI ПРИ РАЗНЫХ СЦЕНАРИЯХ РЫНКА')
      @doc.fill_color Theme::MUTED
      @doc.text 'Что будет с эффективностью инвестиций при оптимистичном, реалистичном и пессимистичном развитии рынка.',
                size: 9
      @doc.fill_color Theme::INK
      @doc.move_down 8

      headers = ['Сценарий', 'Рост цен', 'Ипотека', 'EI наличные', 'EI ипотека', 'EI депозит', 'Лучшая']
      rows = scenarios.map do |s|
        [
          s['scenario_name'],
          "#{s.dig('params', 'price_growth_annual')&.to_f&.round(1)}%",
          "#{s.dig('params', 'mortgage_rate')&.to_f&.round(1)}%",
          fmt_ei(s.dig('cash', 'ei')),
          fmt_ei(s.dig('mortgage', 'ei')),
          fmt_ei(s.dig('deposit', 'ei')),
          strategy_ru(s['best_strategy'])
        ]
      end

      @doc.table([headers] + rows, header: true, width: @doc.bounds.width,
                                   cell_style: { size: 9.5, padding: [7, 7],
                                                 border_color: Theme::HAIRLINE }) do
        row(0).background_color = Theme::INK
        row(0).text_color = 'FFFFFF'
        row(0).font_style = :bold
        row(0).size = 8
        columns(1..6).align = :right
        rows(2..-1).each_with_index do |r, i|
          r.background_color = Theme::TINT if i.odd?
        end
      end
      @doc.move_down 12
    end

    def scenarios_explainer
      explainer(
        'Реалистичный сценарий — то, на что закладываемся по умолчанию (ставки и инфляция от ЦБ РФ). ' \
        'Оптимистичный — если инфляция и рост цен пойдут выше, ставки снизятся. ' \
        'Пессимистичный — обратное. Если "Лучшая" совпадает во всех трёх сценариях — решение устойчивое; ' \
        'если меняется — стоит смотреть на свой прогноз рынка.'
      )
    end

    def sensitivity_section
      sensitivity = Array(@audit['sensitivity_table']).compact_blank
      return if sensitivity.empty?

      section_label('ЧУВСТВИТЕЛЬНОСТЬ EI ИПОТЕКИ К СТАВКЕ')
      @doc.fill_color Theme::MUTED
      @doc.text 'Как меняется EI ипотеки если фактическая ставка отличается от прогнозной. Линия 1.0 — порог окупаемости.',
                size: 9
      @doc.fill_color Theme::INK
      @doc.move_down 10

      AuditPdf::SensitivityChart.new(@doc, sensitivity).render
      @doc.move_down 8

      explainer(
        'Если вам предложили ставку ниже — найдите её на горизонтальной оси и посмотрите EI справа. ' \
        'EI > 1.0 означает, что ипотека на этой ставке уже выгоднее депозита.'
      )
    end

    def page_footer
      @doc.move_cursor_to(40)
      @doc.fill_color Theme::MUTED
      @doc.text "стр. 3  ·  Отчёт #{@v.report_label}", size: 7, align: :center
      @doc.fill_color Theme::INK
    end
  end
end
