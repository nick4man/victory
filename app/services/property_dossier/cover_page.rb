# frozen_string_literal: true

module PropertyDossier
  # A3 — Cover page для premium property dossier.
  # Layout: VICTORY wordmark → hero photo (большое) → property title +
  # address → 4-column quick stats (area / rooms / floor / year) →
  # price (RUB + USD) → signature footer with QR codes.
  class CoverPage
    include AuditPdf::Theme::Helpers

    HERO_HEIGHT = 280   # punkter — большое фото, dominant element

    def initialize(doc, property, locale: I18n.locale, rates: nil)
      @doc = doc
      @p = property
      @locale = locale
      @rates = rates
    end

    def render
      paper_background
      wordmark
      hero_photo
      property_title
      quick_stats
      price_block
      signature_footer
    end

    private

    def paper_background
      @doc.canvas do
        @doc.fill_color AuditPdf::Theme::PAPER
        @doc.fill_rectangle [0, @doc.bounds.height], @doc.bounds.width, @doc.bounds.height
      end
      @doc.fill_color AuditPdf::Theme::INK
    end

    def wordmark
      brand = @locale == :en ? 'VICTORY' : 'АН ВИКТОРИ'
      @doc.move_down 8
      @doc.font(AuditPdf::Theme::FONT_FAMILY, style: :bold) do
        @doc.fill_color AuditPdf::Theme::INK
        @doc.text brand, size: 22, character_spacing: 6
      end
      @doc.move_down 4
      @doc.fill_color AuditPdf::Theme::MUTED
      @doc.font(AuditPdf::Theme::FONT_FAMILY, style: :normal) do
        @doc.text I18n.t('dossier.cover.eyebrow', default: 'PREMIUM PROPERTY'),
                  size: 8, character_spacing: 4
      end
      @doc.fill_color AuditPdf::Theme::INK
      @doc.move_down 14
    end

    def hero_photo
      bytes = primary_image_bytes
      if bytes.nil?
        # Soft fallback — тонированная плашка с placeholder text
        y = @doc.cursor
        @doc.fill_color AuditPdf::Theme::TINT
        @doc.fill_rectangle [0, y], @doc.bounds.width, HERO_HEIGHT
        @doc.fill_color AuditPdf::Theme::MUTED
        @doc.bounding_box([0, y - 110], width: @doc.bounds.width, height: 40) do
          @doc.text I18n.t('dossier.gallery.empty_state', default: 'Photos coming soon'),
                    size: 11, align: :center, character_spacing: 1
        end
        @doc.fill_color AuditPdf::Theme::INK
        @doc.move_cursor_to(y - HERO_HEIGHT - 16)
        return
      end

      begin
        @doc.image StringIO.new(bytes),
                   width: @doc.bounds.width,
                   height: HERO_HEIGHT,
                   position: :center
      rescue StandardError => e
        Rails.logger.warn("[PropertyDossier::CoverPage] hero image embed failed: #{e.class}")
      end
      @doc.move_down 16
    end

    def property_title
      title = build_title
      @doc.font(AuditPdf::Theme::FONT_FAMILY, style: :bold) do
        @doc.fill_color AuditPdf::Theme::INK
        @doc.text title, size: 18, leading: 2
      end
      @doc.move_down 4
      address = @p.address.to_s
      if address.present?
        @doc.fill_color AuditPdf::Theme::MUTED
        @doc.font(AuditPdf::Theme::FONT_FAMILY, style: :normal) do
          @doc.text address, size: 11
        end
        @doc.fill_color AuditPdf::Theme::INK
      end
      @doc.move_down 20
    end

    def quick_stats
      cells = [
        [I18n.t('dossier.cover.area'),  fmt_area(@p.try(:area) || @p.try(:total_area))],
        [I18n.t('dossier.cover.rooms'), @p.try(:rooms)&.to_s || '—'],
        [I18n.t('dossier.cover.floor'), fmt_floor(@p.try(:floor), @p.try(:total_floors))],
        [I18n.t('dossier.cover.year'),  @p.try(:building_year)&.to_s || '—']
      ]
      col_w = @doc.bounds.width / cells.size.to_f
      y_start = @doc.cursor
      cells.each_with_index do |(label, value), i|
        x = i * col_w
        @doc.bounding_box([x, y_start], width: col_w - 10) do
          @doc.fill_color AuditPdf::Theme::MUTED
          @doc.text label, size: 8, character_spacing: 2
          @doc.move_down 4
          @doc.fill_color AuditPdf::Theme::INK
          @doc.font(AuditPdf::Theme::FONT_FAMILY, style: :bold) do
            @doc.text value, size: 13
          end
        end
      end
      @doc.move_cursor_to(y_start - 50)
      @doc.move_down 22
    end

    def price_block
      return if @p.price.blank? || @p.price.to_f <= 0

      @doc.stroke_color AuditPdf::Theme::ACCENT_GOLD
      @doc.line_width 1.4
      @doc.stroke_horizontal_rule
      @doc.move_down 14
      @doc.fill_color AuditPdf::Theme::MUTED
      @doc.text I18n.t('dossier.cover.price'), size: 8, character_spacing: 3
      @doc.move_down 6
      @doc.fill_color AuditPdf::Theme::INK
      @doc.font(AuditPdf::Theme::FONT_FAMILY, style: :bold) do
        @doc.text fmt_rub_usd(@p.price), size: 26
      end
    end

    def signature_footer
      @doc.move_cursor_to(58)
      @doc.stroke_color AuditPdf::Theme::HAIRLINE
      @doc.line_width 0.5
      @doc.stroke_horizontal_rule
      @doc.move_down 8
      @doc.fill_color AuditPdf::Theme::MUTED
      url   = AgencyInfo::WEBSITE_URL
      title = AgencyInfo::NAME
      date  = I18n.l(Date.current)
      @doc.text "#{title}   ·   #{date}   ·   #{url}", size: 7.5, align: :center
      @doc.fill_color AuditPdf::Theme::INK
    end

    # ---- helpers ----

    def build_title
      type_label = property_type_label
      rooms = @p.try(:rooms)
      district = @p.try(:district).to_s.presence

      pieces = []
      if rooms.present? && %w[apartment flat].include?(@p.try(:property_type).to_s)
        pieces << "#{rooms}-комн #{type_label}"
      else
        pieces << type_label
      end
      pieces << "· #{district}" if district
      pieces.compact.join(' ')
    end

    def property_type_label
      slug = @p.try(:property_type).to_s
      case slug
      when 'apartment', 'flat' then 'квартира'
      when 'house'             then 'дом'
      when 'land'              then 'участок'
      when 'commerce', 'commercial' then 'коммерческое помещение'
      when 'room'              then 'комната'
      when 'garage'            then 'гараж'
      else                          'объект недвижимости'
      end
    end

    def fmt_area(value)
      return '—' if value.blank? || value.to_f.zero?
      "#{value.to_f.round(1)} м²"
    end

    def fmt_floor(floor, total)
      return '—' if floor.blank?
      total.present? ? "#{floor}/#{total}" : floor.to_s
    end

    # Загружает binary первой photo (Active Storage). Returns nil если
    # нет attached images или download fail (soft-fail keeps PDF rendering).
    def primary_image_bytes
      return nil unless @p.respond_to?(:images) && @p.images.attached?

      blob = @p.images.blobs.first
      return nil if blob.nil?

      blob.download
    rescue StandardError => e
      Rails.logger.warn("[PropertyDossier::CoverPage] primary_image_bytes failed: #{e.class}")
      nil
    end
  end
end
