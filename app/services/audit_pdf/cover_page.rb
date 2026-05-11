# frozen_string_literal: true

module AuditPdf
  # Page 1 — cover. Big wordmark, property summary, hero verdict band,
  # signature footer. Single-page; no other content.
  class CoverPage
    include Theme::Helpers

    def initialize(doc, valuation, audit, monte_carlo)
      @doc = doc
      @v = valuation
      @audit = audit || {}
      @mc = monte_carlo || {}
    end

    def render
      paper_background
      wordmark
      property_summary
      verdict_hero
      signature_footer
    end

    private

    def paper_background
      @doc.canvas do
        @doc.fill_color Theme::PAPER
        @doc.fill_rectangle [0, @doc.bounds.height], @doc.bounds.width, @doc.bounds.height
      end
      @doc.fill_color Theme::INK
    end

    def wordmark
      @doc.move_down 20
      @doc.font(Theme::FONT_FAMILY, style: :bold) do
        @doc.fill_color Theme::INK
        @doc.text 'АН ВИКТОРИ', size: 32, character_spacing: 8
      end
      @doc.move_down 6
      @doc.font(Theme::FONT_FAMILY, style: :normal) do
        @doc.fill_color Theme::MUTED
        @doc.text 'Агентство недвижимости в Рязани', size: 10, character_spacing: 1
      end
      @doc.move_down 18
      @doc.stroke_color Theme::ACCENT_GOLD
      @doc.line_width 1.4
      @doc.stroke_horizontal_rule
      @doc.move_down 6
      @doc.fill_color Theme::MUTED
      @doc.font(Theme::FONT_FAMILY, style: :normal) do
        @doc.text 'Инвестиционный аудит недвижимости', size: 11, character_spacing: 4
      end
      @doc.fill_color Theme::INK
      @doc.move_down 22
      @doc.fill_color Theme::INK_SOFT
      @doc.font(Theme::FONT_FAMILY, style: :bold) do
        @doc.text "ОТЧЁТ #{@v.report_label}", size: 13, character_spacing: 5
      end
      @doc.fill_color Theme::INK
      @doc.move_down 38
    end

    def property_summary
      section_label('ОБЪЕКТ АУДИТА')
      @doc.move_down 4

      address = (@v.address.presence || @audit['complex_name']).to_s
      @doc.font(Theme::FONT_FAMILY, style: :bold) do
        @doc.text address, size: 14
      end
      @doc.move_down 18

      # 3-column key-numbers grid
      area = @audit['area_sqm']&.to_f
      area_text = area ? "#{area.round(1)} м²" : '—'
      price_text = fmt_rub(@audit['price_total'])
      ppsm_text = "#{fmt_rub(@audit['price_per_sqm'])}/м²"

      cols = [
        ['ПЛОЩАДЬ',   area_text],
        ['ЦЕНА',      price_text],
        ['ЗА КВ. МЕТР', ppsm_text]
      ]
      col_width = @doc.bounds.width / 3.0
      y_start = @doc.cursor
      cols.each_with_index do |(label, value), i|
        x = i * col_width
        @doc.bounding_box([x, y_start], width: col_width - 12) do
          @doc.fill_color Theme::MUTED
          @doc.text label, size: 8, character_spacing: 2
          @doc.move_down 4
          @doc.fill_color Theme::INK
          @doc.font(Theme::FONT_FAMILY, style: :bold) do
            @doc.text value, size: 14
          end
        end
      end
      @doc.move_cursor_to(y_start - 50)
      @doc.move_down 50
    end

    def verdict_hero
      verdict = @audit['verdict'].to_s
      bg = Theme::VERDICT_BG[verdict] || Theme::TINT
      fg = Theme::VERDICT_FG[verdict] || Theme::INK

      box_h = 180
      y_top = @doc.cursor
      box_w = @doc.bounds.width

      @doc.fill_color bg
      @doc.fill_rectangle [0, y_top], box_w, box_h
      @doc.fill_color fg

      @doc.bounding_box([24, y_top - 24], width: box_w - 48, height: box_h - 40) do
        @doc.fill_color fg
        @doc.font(Theme::FONT_FAMILY, style: :bold) do
          @doc.text 'ВЕРДИКТ', size: 9, character_spacing: 4
        end
        @doc.move_down 12
        @doc.font(Theme::FONT_FAMILY, style: :bold) do
          @doc.text verdict_ru(verdict), size: 48
        end
        @doc.move_down 8
        explanation = @audit['verdict_explanation'].to_s.truncate(220)
        @doc.font(Theme::FONT_FAMILY, style: :normal) do
          @doc.fill_color fg
          @doc.text explanation, size: 11, leading: 3 if explanation.present?
        end
      end

      @doc.move_cursor_to(y_top - box_h - 10)
      @doc.fill_color Theme::INK

      if (rec = @mc['recommended_strategy']).present?
        conf = Theme::CONFIDENCE_RU[@mc['confidence_level']] || @mc['confidence_level']
        line = "Лучшая стратегия — #{strategy_ru(rec)}"
        line += " (#{conf})" if conf
        @doc.fill_color Theme::INK_SOFT
        @doc.text line, size: 11, align: :center
        @doc.fill_color Theme::INK
      end
    end

    def signature_footer
      # QR row — print 2 codes (TG + site) above the date/url line.
      draw_qr_row

      # Push to bottom of page after QR row.
      @doc.move_cursor_to(48)
      @doc.stroke_color Theme::HAIRLINE
      @doc.line_width 0.5
      @doc.stroke_horizontal_rule
      @doc.move_down 8
      @doc.fill_color Theme::MUTED
      left = "Дата аудита: #{@audit['audit_date'] || I18n.l(Date.current)}"
      right = AgencyInfo::WEBSITE_URL
      mid = "Отчёт #{@v.report_label}"
      @doc.text "#{left}   ·   #{mid}   ·   #{right}", size: 7.5, align: :center
      @doc.fill_color Theme::INK
    end

    # Two side-by-side QR codes: site URL on the left, Telegram channel on
    # the right. Sits just above the signature footer. Skipped silently if
    # rqrcode is unavailable (graceful degrade — date/url line still prints).
    def draw_qr_row
      tg_url   = 'https://t.me/rznvictory'
      site_url = AgencyInfo::WEBSITE_URL

      site_png = QrRenderer.png(site_url, size: 200)
      tg_png   = QrRenderer.png(tg_url,   size: 200)
      return if site_png.nil? && tg_png.nil?

      @doc.move_cursor_to(125)
      qr_h = 70 # rendered height in PDF points
      gap  = 40

      # Centre the two QR blocks on the page width.
      page_w  = @doc.bounds.width
      block_w = (qr_h * 2) + gap + 200 # rough — text col under each QR adds width
      x_left  = (page_w - block_w) / 2.0

      begin
        if site_png
          @doc.image StringIO.new(site_png), at: [x_left, @doc.cursor], width: qr_h, height: qr_h
          @doc.bounding_box([x_left + qr_h + 8, @doc.cursor], width: 110, height: qr_h) do
            @doc.fill_color Theme::MUTED
            @doc.text 'НАШ САЙТ', size: 7, character_spacing: 1.5
            @doc.fill_color Theme::INK
            @doc.text site_url.sub(%r{^https?://}, ''), size: 8
          end
        end

        x_right = x_left + qr_h + 200 + gap
        if tg_png
          @doc.image StringIO.new(tg_png), at: [x_right, @doc.cursor], width: qr_h, height: qr_h
          @doc.bounding_box([x_right + qr_h + 8, @doc.cursor], width: 110, height: qr_h) do
            @doc.fill_color Theme::MUTED
            @doc.text 'TELEGRAM', size: 7, character_spacing: 1.5
            @doc.fill_color Theme::INK
            @doc.text '@rznvictory', size: 8
            @doc.move_down 2
            @doc.fill_color Theme::MUTED
            @doc.text 'новости каждые 15 мин', size: 6.5
          end
        end
      rescue StandardError => e
        Rails.logger.warn("[AuditPdf::CoverPage] QR embed failed: #{e.class} #{e.message}")
      ensure
        @doc.fill_color Theme::INK
      end
    end
  end
end
