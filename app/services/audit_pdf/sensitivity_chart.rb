# frozen_string_literal: true

module AuditPdf
  # Draws a small line chart of EI vs mortgage rate directly in Prawn —
  # no SVG embed, no external dependency. Renders inside the current cursor
  # position with `bounds.width × 200pt`.
  #
  # Data input: array of `{ "rate" => float, "ei" => float, ... }` from
  # the engine's audit `sensitivity_table`.
  class SensitivityChart
    CHART_HEIGHT = 180
    PAD_LEFT     = 30
    PAD_RIGHT    = 14
    PAD_TOP      = 14
    PAD_BOTTOM   = 28

    def initialize(doc, sensitivity)
      @doc = doc
      @rows = sensitivity.map { |r| [r['rate'].to_f, r['ei'].to_f] }
                          .sort_by(&:first)
    end

    def render
      return if @rows.size < 2

      width  = @doc.bounds.width
      height = CHART_HEIGHT
      y_top  = @doc.cursor

      @doc.bounding_box([0, y_top], width: width, height: height) do
        x_min, x_max = @rows.map(&:first).minmax
        y_vals = @rows.map(&:last)
        y_min = [0.0, y_vals.min].min
        y_max = [1.2, y_vals.max].max
        y_min = (y_min * 0.95).floor(1)
        y_max = (y_max * 1.05).ceil(1)

        chart_x0 = PAD_LEFT
        chart_y0 = PAD_BOTTOM
        chart_w  = width - PAD_LEFT - PAD_RIGHT
        chart_h  = height - PAD_TOP - PAD_BOTTOM

        x_of = ->(rate) { chart_x0 + (rate - x_min).to_f / (x_max - x_min) * chart_w }
        y_of = ->(ei)   { chart_y0 + (ei - y_min).to_f / (y_max - y_min) * chart_h }

        # Frame
        @doc.stroke_color Theme::HAIRLINE
        @doc.line_width 0.5
        @doc.stroke_rectangle [chart_x0, chart_y0 + chart_h], chart_w, chart_h

        # EI=1.0 threshold line — dashed
        if y_min <= 1.0 && y_max >= 1.0
          @doc.dash(3, space: 3)
          @doc.stroke_color Theme::MUTED
          @doc.line_width 0.7
          @doc.stroke_line [chart_x0, y_of.call(1.0)], [chart_x0 + chart_w, y_of.call(1.0)]
          @doc.undash
          # Label "EI = 1.0"
          @doc.fill_color Theme::MUTED
          @doc.draw_text 'EI = 1.0', at: [chart_x0 + chart_w - 50, y_of.call(1.0) + 3], size: 7
        end

        # Y-axis labels (just top + bottom + threshold)
        @doc.fill_color Theme::MUTED
        [y_min, y_max].each do |y|
          @doc.draw_text y.round(2).to_s, at: [chart_x0 - 26, y_of.call(y) - 2], size: 7
        end

        # X-axis labels (5 points)
        [x_min, (x_min + x_max) / 2.0, x_max].each do |x|
          @doc.draw_text "#{x.round}%", at: [x_of.call(x) - 8, chart_y0 - 12], size: 7
        end
        @doc.fill_color Theme::INK

        # Line plot
        @doc.stroke_color Theme::INK
        @doc.line_width 1.4
        prev = nil
        @rows.each do |(rate, ei)|
          pt = [x_of.call(rate), y_of.call(ei)]
          @doc.stroke_line(prev, pt) if prev
          prev = pt
        end

        # Caption under x-axis
        @doc.fill_color Theme::MUTED
        @doc.draw_text 'Ставка ипотеки, %', at: [chart_x0 + chart_w / 2 - 40, chart_y0 - 26], size: 7
        @doc.fill_color Theme::INK
      end

      @doc.move_cursor_to(y_top - CHART_HEIGHT)
    end
  end
end
