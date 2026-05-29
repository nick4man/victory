# frozen_string_literal: true

module AuditPdf
  # Page 2 — Efficiency Index breakdown + mortgage details.
  # Three EI strategies + Monte Carlo p5-p95 + mortgage key numbers + plain-language
  # "what this means" callouts after each block. i18n: audit.ei.* via current locale.
  class EiDetailsPage
    include Theme::Helpers

    def initialize(doc, valuation, audit, monte_carlo, locale: I18n.locale, rates: nil)
      @doc = doc
      @v = valuation
      @audit = audit || {}
      @mc = monte_carlo || {}
      @locale = locale
      @rates = rates
    end

    def render
      @doc.start_new_page
      paint_paper
      page_header
      ei_table
      ei_explainer
      mortgage_block
      mortgage_explainer
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
        @doc.fill_color Theme::INK
        @doc.text I18n.t('audit.ei.page_title').upcase, size: 18
      end
      @doc.move_down 6
      @doc.stroke_color Theme::ACCENT_GOLD
      @doc.line_width 1
      @doc.stroke_horizontal_rule
      @doc.move_down 18
    end

    def ei_table
      section_label(I18n.t('audit.ei.three_strategies_header'))
      @doc.fill_color Theme::MUTED
      @doc.font(Theme::FONT_FAMILY, style: :normal) do
        @doc.text I18n.t('audit.ei.threshold_legend'), size: 9
      end
      @doc.fill_color Theme::INK
      @doc.move_down 8

      rec_key = @mc['recommended_strategy'].to_s.downcase
      headers = [
        I18n.t('audit.ei.strategy'),
        I18n.t('audit.ei.median_index'),
        I18n.t('audit.ei.p5_p95_range'),
        I18n.t('audit.ei.buy_probability')
      ]
      cash_label_full = "#{strategy_label('cash')} (100%)"
      rows = [
        ['cash',     cash_label_full,            @audit['ei_cash'],     @mc['cash']],
        ['mortgage', strategy_label('mortgage'), @audit['ei_mortgage'], @mc['mortgage']],
        ['deposit',  strategy_label('deposit'),  @audit['ei_deposit'],  @mc['deposit']]
      ].map do |key, label, ei, mc_s|
        marker = key == rec_key ? '  ◆' : ''
        [
          label + marker,
          fmt_ei(ei),
          mc_s ? "#{mc_s['ei_p5']&.to_f&.round(2)}–#{mc_s['ei_p95']&.to_f&.round(2)}" : '—',
          mc_s ? "#{mc_s['buy_probability'].to_f.round(1)}%" : '—'
        ]
      end

      @doc.table([headers] + rows, header: true, width: @doc.bounds.width,
                                   cell_style: { size: 10.5, padding: [9, 10],
                                                 border_color: Theme::HAIRLINE,
                                                 inline_format: true }) do
        row(0).background_color = Theme::INK
        row(0).text_color = 'FFFFFF'
        row(0).font_style = :bold
        row(0).size = 9
        columns(1..3).align = :right
        rows(2..-1).each_with_index do |r, i|
          r.background_color = Theme::TINT if i.odd?
        end
      end
      @doc.move_down 6
      @doc.fill_color Theme::MUTED
      @doc.text I18n.t('audit.ei.recommended_marker_note'), size: 8
      @doc.fill_color Theme::INK
      @doc.move_down 14
    end

    def ei_explainer
      explainer(I18n.t('audit.ei.explainer_full'))
    end

    def mortgage_block
      m = realistic_mortgage
      return unless m

      section_label(I18n.t('audit.ei.mortgage_terms_header'))
      @doc.move_down 4

      rows = [
        [I18n.t('audit.ei.down_payment'),    fmt_rub_usd(m['down_payment'])],
        [I18n.t('audit.ei.loan_amount'),     fmt_rub_usd(m['loan_amount'])],
        [I18n.t('audit.ei.monthly_payment'), fmt_rub_usd(m['monthly_payment'])],
        [I18n.t('audit.ei.total_payments'),  fmt_rub_usd(m['total_payments'])],
        [I18n.t('audit.ei.total_interest'),  fmt_rub_usd(m['total_interest'])]
      ]
      @doc.table(rows, cell_style: { borders: [:bottom], border_color: Theme::HAIRLINE,
                                     padding: [7, 0], size: 11 },
                       width: @doc.bounds.width) do
        column(0).text_color = Theme::INK_SOFT
        column(1).align = :right
        column(1).font_style = :bold
      end
      @doc.move_down 12
    end

    def mortgage_explainer
      m = realistic_mortgage
      return unless m

      explainer(
        I18n.t('audit.ei.mortgage_explainer',
               total_payments: fmt_rub(m['total_payments']))
      )
    end

    def page_footer
      @doc.move_cursor_to(40)
      @doc.fill_color Theme::MUTED
      @doc.text I18n.t('audit.page_footer', page: 2, report: @v.report_label), size: 7, align: :center
      @doc.fill_color Theme::INK
    end

    def realistic_mortgage
      @realistic ||= begin
        ss = Array(@audit['scenarios'])
        s = ss.find { |r| r['scenario_name'] == 'Реалистичный' } || ss[1] || ss.first
        s&.dig('mortgage')
      end
    end
  end
end
