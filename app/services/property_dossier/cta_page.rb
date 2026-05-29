# frozen_string_literal: true

module PropertyDossier
  # A3 — Final CTA + legal disclaimer page.
  # Layout: book-viewing instructions → what-we-prepare list → site/TG QR
  # row → legal disclaimer (small italic).
  class CtaPage
    include AuditPdf::Theme::Helpers

    def initialize(doc, property, locale: I18n.locale, rates: nil)
      @doc = doc
      @p = property
      @locale = locale
      @rates = rates
    end

    def render
      @doc.start_new_page
      paint_paper
      page_header
      book_viewing_block
      what_we_provide_block
      qr_row
      disclaimer_block
      page_footer
    end

    private

    def paint_paper
      @doc.canvas do
        @doc.fill_color AuditPdf::Theme::PAPER
        @doc.fill_rectangle [0, @doc.bounds.height], @doc.bounds.width, @doc.bounds.height
      end
      @doc.fill_color AuditPdf::Theme::INK
    end

    def page_header
      @doc.font(AuditPdf::Theme::FONT_FAMILY, style: :bold) do
        @doc.text I18n.t('dossier.cta.page_title').upcase, size: 18
      end
      @doc.move_down 6
      @doc.stroke_color AuditPdf::Theme::ACCENT_GOLD
      @doc.line_width 1
      @doc.stroke_horizontal_rule
      @doc.move_down 22
    end

    def book_viewing_block
      section_label(I18n.t('dossier.cta.book_viewing_header'))
      @doc.move_down 6
      @doc.fill_color AuditPdf::Theme::INK_SOFT
      @doc.text I18n.t('dossier.cta.book_viewing_body'),
                size: 11, leading: 3, align: :justify
      @doc.fill_color AuditPdf::Theme::INK
      @doc.move_down 18
    end

    def what_we_provide_block
      section_label(I18n.t('dossier.cta.what_we_provide_header'))
      @doc.move_down 6

      items = Array(I18n.t('dossier.cta.what_we_provide_items', default: []))
      items.each do |item|
        @doc.font(AuditPdf::Theme::FONT_FAMILY, style: :normal) do
          @doc.fill_color AuditPdf::Theme::ACCENT_GOLD
          @doc.text '▸ ', size: 10, inline_format: true
        end
        @doc.move_cursor_to(@doc.cursor + 12)
        @doc.fill_color AuditPdf::Theme::INK_SOFT
        @doc.font(AuditPdf::Theme::FONT_FAMILY, style: :normal) do
          @doc.indent(16) do
            @doc.text item, size: 10, leading: 2.5
          end
        end
        @doc.fill_color AuditPdf::Theme::INK
        @doc.move_down 6
      end
      @doc.move_down 12
    end

    def qr_row
      site_url = AgencyInfo::WEBSITE_URL
      tg_url   = 'https://t.me/rznvictory'

      site_png = QrRenderer.png(site_url) rescue nil
      tg_png   = QrRenderer.png(tg_url)   rescue nil
      return if site_png.nil? && tg_png.nil?

      qr_h = 80
      gap  = 60
      page_w = @doc.bounds.width
      block_w = (qr_h * 2) + gap + 200
      x_left = (page_w - block_w) / 2.0
      y = @doc.cursor

      if site_png
        @doc.image StringIO.new(site_png), at: [x_left, y], width: qr_h, height: qr_h
        @doc.bounding_box([x_left + qr_h + 8, y], width: 100, height: qr_h) do
          @doc.fill_color AuditPdf::Theme::MUTED
          @doc.text I18n.t('dossier.cta.website_cta').upcase, size: 7, character_spacing: 1.5
          @doc.fill_color AuditPdf::Theme::INK
          @doc.text site_url.sub(%r{^https?://}, ''), size: 9
        end
      end

      x_right = x_left + qr_h + 100 + gap
      if tg_png
        @doc.image StringIO.new(tg_png), at: [x_right, y], width: qr_h, height: qr_h
        @doc.bounding_box([x_right + qr_h + 8, y], width: 100, height: qr_h) do
          @doc.fill_color AuditPdf::Theme::MUTED
          @doc.text I18n.t('dossier.cta.tg_cta').upcase, size: 7, character_spacing: 1.5
          @doc.fill_color AuditPdf::Theme::INK
          @doc.text '@rznvictory', size: 9
        end
      end

      @doc.move_cursor_to(y - qr_h - 24)
    rescue StandardError => e
      Rails.logger.warn("[PropertyDossier::CtaPage] qr_row failed: #{e.class}")
    end

    def disclaimer_block
      @doc.stroke_color AuditPdf::Theme::HAIRLINE
      @doc.line_width 0.5
      @doc.stroke_horizontal_rule
      @doc.move_down 10

      @doc.font(AuditPdf::Theme::FONT_FAMILY, style: :bold) do
        @doc.fill_color AuditPdf::Theme::INK
        @doc.text I18n.t('dossier.cta.disclaimer_header').upcase,
                  size: 8, character_spacing: 3
      end
      @doc.move_down 4
      @doc.fill_color AuditPdf::Theme::MUTED
      @doc.font(AuditPdf::Theme::FONT_FAMILY, style: :italic) do
        @doc.text I18n.t('dossier.cta.disclaimer'), size: 8, leading: 2, align: :justify
      end
      @doc.fill_color AuditPdf::Theme::INK
    end

    def page_footer
      @doc.move_cursor_to(40)
      @doc.fill_color AuditPdf::Theme::MUTED
      @doc.text I18n.t('dossier.page_footer', page: 5, report: report_label),
                size: 7, align: :center
      @doc.fill_color AuditPdf::Theme::INK
    end

    def report_label
      @p.try(:slug) || "##{@p.id}"
    end
  end
end
