# frozen_string_literal: true

module AuditPdf
  # Page 3 — three market scenarios + sensitivity chart.
  # Helps the reader see how the verdict shifts under different macro
  # conditions, especially how mortgage-rate moves affect the EI. i18n: audit.scenarios.*
  class ScenariosPage
    include Theme::Helpers

    def initialize(doc, valuation, audit, _monte_carlo, locale: I18n.locale, rates: nil)
      @doc = doc
      @v = valuation
      @audit = audit || {}
      @locale = locale
      @rates = rates
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
        @doc.text I18n.t('audit.scenarios.page_title').upcase, size: 18
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

      section_label(I18n.t('audit.scenarios.ei_by_market_header'))
      @doc.fill_color Theme::MUTED
      @doc.text I18n.t('audit.scenarios.intro'), size: 9
      @doc.fill_color Theme::INK
      @doc.move_down 8

      headers = [
        I18n.t('audit.scenarios.scenario_col'),
        I18n.t('audit.scenarios.price_growth_col'),
        I18n.t('audit.scenarios.mortgage_col'),
        I18n.t('audit.scenarios.ei_cash_col'),
        I18n.t('audit.scenarios.ei_mortgage_col'),
        I18n.t('audit.scenarios.ei_deposit_col'),
        I18n.t('audit.scenarios.best_col')
      ]
      rows = scenarios.map do |s|
        [
          translate_scenario_name(s['scenario_name']),
          "#{s.dig('params', 'price_growth_annual')&.to_f&.round(1)}%",
          "#{s.dig('params', 'mortgage_rate')&.to_f&.round(1)}%",
          fmt_ei(s.dig('cash', 'ei')),
          fmt_ei(s.dig('mortgage', 'ei')),
          fmt_ei(s.dig('deposit', 'ei')),
          strategy_label(s['best_strategy'])
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

    # Python audit-engine returns scenario_name на RU («Реалистичный»,
    # «Оптимистичный», «Пессимистичный»). Маппим на i18n для EN PDF.
    def translate_scenario_name(name)
      key = case name.to_s
            when 'Реалистичный'  then 'realistic'
            when 'Оптимистичный' then 'optimistic'
            when 'Пессимистичный' then 'pessimistic'
            end
      key ? I18n.t("audit.scenarios.names.#{key}", default: name) : name.to_s
    end

    def scenarios_explainer
      explainer(I18n.t('audit.scenarios.explainer_full'))
    end

    def sensitivity_section
      sensitivity = Array(@audit['sensitivity_table']).compact_blank
      return if sensitivity.empty?

      section_label(I18n.t('audit.scenarios.sensitivity_header'))
      @doc.fill_color Theme::MUTED
      @doc.text I18n.t('audit.scenarios.sensitivity_intro'), size: 9
      @doc.fill_color Theme::INK
      @doc.move_down 10

      AuditPdf::SensitivityChart.new(@doc, sensitivity).render
      @doc.move_down 8

      explainer(I18n.t('audit.scenarios.sensitivity_explainer'))
    end

    def page_footer
      @doc.move_cursor_to(40)
      @doc.fill_color Theme::MUTED
      @doc.text I18n.t('audit.page_footer', page: 3, report: @v.report_label), size: 7, align: :center
      @doc.fill_color Theme::INK
    end
  end
end
