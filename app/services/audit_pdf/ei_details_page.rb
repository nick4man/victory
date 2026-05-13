# frozen_string_literal: true

module AuditPdf
  # Page 2 — Efficiency Index breakdown + mortgage details.
  # Three EI strategies + Monte Carlo p5-p95 + mortgage key numbers + plain-Russian
  # "what this means" callouts after each block.
  class EiDetailsPage
    include Theme::Helpers

    def initialize(doc, valuation, audit, monte_carlo)
      @doc = doc
      @v = valuation
      @audit = audit || {}
      @mc = monte_carlo || {}
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
        @doc.text 'ЭФФЕКТИВНОСТЬ ИНВЕСТИЦИИ', size: 18
      end
      @doc.move_down 6
      @doc.stroke_color Theme::ACCENT_GOLD
      @doc.line_width 1
      @doc.stroke_horizontal_rule
      @doc.move_down 18
    end

    def ei_table
      section_label('РЕЗУЛЬТАТ ПО ТРЁМ СТРАТЕГИЯМ')
      @doc.fill_color Theme::MUTED
      @doc.font(Theme::FONT_FAMILY, style: :normal) do
        @doc.text 'EI ≥ 1.2 — покупать выгоднее альтернатив · 0.9–1.1 — нейтрально · < 0.8 — невыгодно',
                  size: 9
      end
      @doc.fill_color Theme::INK
      @doc.move_down 8

      rec_key = @mc['recommended_strategy'].to_s.downcase
      headers = ['Стратегия', 'Индекс (медиана)', 'Интервал p5–p95', 'Вероятность выгоды']
      rows = [
        ['cash',     'Наличными (100%)', @audit['ei_cash'],     @mc['cash']],
        ['mortgage', 'Ипотека',           @audit['ei_mortgage'], @mc['mortgage']],
        ['deposit',  'Депозит',           @audit['ei_deposit'],  @mc['deposit']]
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
      @doc.text '◆ — стратегия, рекомендованная по итогам Монте-Карло (1 000 000 симуляций).',
                size: 8
      @doc.fill_color Theme::INK
      @doc.move_down 14
    end

    def ei_explainer
      explainer(
        'Если по конкретной стратегии EI > 1.2 — этот способ покупки сейчас выгоднее, чем альтернатива ' \
        '(депозит или съём + накопление). Если EI < 0.8 — деньги работают эффективнее в другом инструменте. ' \
        'Вероятность выгоды показывает шанс остаться в плюсе при тысячах разных вариантов будущего.'
      )
    end

    def mortgage_block
      m = realistic_mortgage
      return unless m

      section_label('УСЛОВИЯ ИПОТЕКИ (РЕАЛИСТИЧНЫЙ СЦЕНАРИЙ)')
      @doc.move_down 4

      rows = [
        ['Первый взнос',   fmt_rub(m['down_payment'])],
        ['Тело кредита',   fmt_rub(m['loan_amount'])],
        ['Платёж в месяц', fmt_rub(m['monthly_payment'])],
        ['Всего выплат за срок', fmt_rub(m['total_payments'])],
        ['Переплата (проценты)', fmt_rub(m['total_interest'])]
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
        "«Всего выплат» #{fmt_rub(m['total_payments'])} — это сумма всех ежемесячных платежей за весь срок ипотеки " \
        '(обычно 20 лет). Аудит считает решение на горизонте 5 лет — поэтому EI учитывает только то, что выплачено за эти 5 лет ' \
        'плюс остаточный долг, а не всю переплату за 20 лет. Снижение ставки на 1% существенно меняет индекс эффективности (см. стр. 3).'
      )
    end

    def page_footer
      @doc.move_cursor_to(40)
      @doc.fill_color Theme::MUTED
      @doc.text "стр. 2  ·  Отчёт #{@v.report_label}", size: 7, align: :center
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
