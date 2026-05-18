# frozen_string_literal: true

module PropertyDossier
  # A3 — Gallery page. Grid 2x3 (до 6 фото на странице). Если фото больше —
  # обрезаем до 6 (Cover already shows the 1st as hero, gallery starts from
  # #2 to avoid duplication). Soft-fail на отдельных broken blobs — каждое
  # фото embedds в rescue StandardError, чтобы один corrupted file не
  # ронял всю dossier.
  class GalleryPage
    include AuditPdf::Theme::Helpers

    MAX_PHOTOS = 6
    GRID_COLS  = 2
    GRID_ROWS  = 3
    GAP        = 10   # пункты между cells

    def initialize(doc, property, locale: I18n.locale, rates: nil)
      @doc = doc
      @p = property
      @locale = locale
      @rates = rates
    end

    def render
      photos = collect_photos
      return if photos.empty?  # skip page entirely if no usable images

      @doc.start_new_page
      paint_paper
      page_header(photos.size)
      photo_grid(photos)
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

    def page_header(count)
      @doc.font(AuditPdf::Theme::FONT_FAMILY, style: :bold) do
        @doc.text I18n.t('dossier.gallery.page_title').upcase, size: 18
      end
      @doc.move_down 6
      @doc.stroke_color AuditPdf::Theme::ACCENT_GOLD
      @doc.line_width 1
      @doc.stroke_horizontal_rule
      @doc.move_down 6
      @doc.fill_color AuditPdf::Theme::MUTED
      @doc.text I18n.t('dossier.gallery.photos_count', count: count, default: "#{count} фото"),
                size: 9
      @doc.fill_color AuditPdf::Theme::INK
      @doc.move_down 14
    end

    def photo_grid(photos)
      total_w = @doc.bounds.width
      cell_w = (total_w - GAP * (GRID_COLS - 1)) / GRID_COLS.to_f
      cell_h = 180

      y = @doc.cursor
      photos.each_with_index do |bytes, idx|
        col = idx % GRID_COLS
        row = idx / GRID_COLS
        x   = col * (cell_w + GAP)
        cy  = y - row * (cell_h + GAP)

        # Cell background tint (для пустого state если image fail)
        @doc.fill_color AuditPdf::Theme::TINT
        @doc.fill_rectangle [x, cy], cell_w, cell_h
        @doc.fill_color AuditPdf::Theme::INK

        begin
          @doc.image StringIO.new(bytes),
                     at: [x, cy],
                     width: cell_w,
                     height: cell_h,
                     position: :center,
                     vposition: :center
        rescue StandardError => e
          Rails.logger.warn("[PropertyDossier::GalleryPage] photo ##{idx} embed failed: #{e.class}")
          # Cell остаётся tinted placeholder — не ломает grid.
        end
      end
      # Move cursor below grid
      total_rows = (photos.size.to_f / GRID_COLS).ceil
      @doc.move_cursor_to(y - total_rows * cell_h - (total_rows - 1) * GAP - 20)
    end

    def page_footer
      @doc.move_cursor_to(40)
      @doc.fill_color AuditPdf::Theme::MUTED
      @doc.text I18n.t('dossier.page_footer', page: 2, report: report_label),
                size: 7, align: :center
      @doc.fill_color AuditPdf::Theme::INK
    end

    # Skip 1st photo (used as hero on cover) — gallery starts from photo #2.
    # Caps at MAX_PHOTOS, drops nils.
    def collect_photos
      return [] unless @p.respond_to?(:images) && @p.images.attached?

      blobs = @p.images.blobs.to_a.drop(1).first(MAX_PHOTOS)
      blobs.filter_map do |blob|
        blob.download
      rescue StandardError => e
        Rails.logger.warn("[PropertyDossier::GalleryPage] blob #{blob.id} download failed: #{e.class}")
        nil
      end
    end

    def report_label
      @p.try(:friendly_id) || @p.try(:slug) || "##{@p.id}"
    end
  end
end
