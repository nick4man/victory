# frozen_string_literal: true

module AuditPdf
  # Optional 5th page — multi-offer Monte Carlo across the bank-offers
  # catalogue. Skipped entirely when the engine returned no `per_offer`
  # array (нет банков, нет данных). Recommended program highlighted.
  class BankOffersPage
    include Theme::Helpers

    MAX_OFFERS = 10

    def initialize(doc, valuation, _audit, _monte_carlo)
      @doc = doc
      @v = valuation
      @bank_offers = (valuation.evaluation_data || {})['bank_offers'] || {}
    end

    def render
      offers = Array(@bank_offers['per_offer']).compact_blank
      return if offers.empty?

      @doc.start_new_page
      paint_paper
      page_header
      recommendation_callout
      offers_table(offers.first(MAX_OFFERS))
      explainer(
        'Все программы прошли отдельную Monte Carlo (50 000 симуляций каждая) ' \
        'с учётом своих ставок и требований к первому взносу. EI считается так же, как для одной ' \
        'базовой программы. Рекомендованная — с максимальным EI median; если EI < 1.0 у всех — ' \
        'программа отмечена, но это означает, что покупать в ипотеку сейчас невыгодно для этого объекта.'
      )
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
        @doc.text 'ИПОТЕЧНЫЕ ПРОГРАММЫ', size: 18
      end
      @doc.move_down 6
      @doc.stroke_color Theme::ACCENT_GOLD
      @doc.line_width 1
      @doc.stroke_horizontal_rule
      @doc.move_down 18
    end

    def recommendation_callout
      bank    = @bank_offers['recommended_bank']
      product = @bank_offers['recommended_product']
      return if bank.blank?

      section_label('РЕКОМЕНДОВАНО ПО ИТОГАМ MULTI-OFFER MC')
      @doc.move_down 4
      @doc.font(Theme::FONT_FAMILY, style: :bold) { @doc.text bank, size: 14 }
      @doc.move_down 2
      @doc.fill_color Theme::INK_SOFT
      @doc.text product.to_s, size: 11
      @doc.fill_color Theme::INK
      @doc.move_down 14
    end

    def offers_table(offers)
      section_label('ПРОГРАММЫ ПО EI MEDIAN (ОТСОРТИРОВАНЫ ПО ВЫГОДНОСТИ)')
      @doc.move_down 4

      recommended_id = @bank_offers['recommended_offer_id']
      headers = ['Банк', 'Программа', 'Ставка', 'EI median', 'p5–p95', 'P(BUY)']
      rows = offers.map do |po|
        offer = po['offer'] || {}
        marker = offer['id'] == recommended_id ? '  ◆' : ''
        [
          (offer['bank_name'].to_s + marker),
          offer['product_name'].to_s.truncate(38),
          "#{po['effective_rate']&.to_f&.round(2)}%",
          po['ei_mortgage_median']&.to_f&.round(2).to_s,
          "#{po['ei_mortgage_p5']&.to_f&.round(2)}–#{po['ei_mortgage_p95']&.to_f&.round(2)}",
          "#{po['buy_probability'].to_f.round(1)}%"
        ]
      end

      @doc.table([headers] + rows, header: true, width: @doc.bounds.width,
                                   cell_style: { size: 8.5, padding: [5, 6],
                                                 border_color: Theme::HAIRLINE }) do
        row(0).background_color = Theme::INK
        row(0).text_color = 'FFFFFF'
        row(0).font_style = :bold
        row(0).size = 7.5
        columns(2..5).align = :right
        rows(2..-1).each_with_index do |r, i|
          r.background_color = Theme::TINT if i.odd?
        end
      end
      @doc.move_down 8
    end

    def page_footer
      @doc.move_cursor_to(40)
      @doc.fill_color Theme::MUTED
      @doc.text "стр. 5  ·  Отчёт #{@v.report_label}", size: 7, align: :center
      @doc.fill_color Theme::INK
    end
  end
end
