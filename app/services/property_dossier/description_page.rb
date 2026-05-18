# frozen_string_literal: true

module PropertyDossier
  # A3 — Description page: features table + location + full description text.
  # 2-column layout: left=features, right=location; full-width description below.
  class DescriptionPage
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
      two_column_specs
      description_block
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
        @doc.text I18n.t('dossier.description.page_title').upcase, size: 18
      end
      @doc.move_down 6
      @doc.stroke_color AuditPdf::Theme::ACCENT_GOLD
      @doc.line_width 1
      @doc.stroke_horizontal_rule
      @doc.move_down 18
    end

    def two_column_specs
      col_w = (@doc.bounds.width - 30) / 2.0
      y = @doc.cursor

      @doc.bounding_box([0, y], width: col_w) do
        section_label(I18n.t('dossier.description.features_header'))
        @doc.move_down 6
        render_kv_table(feature_rows)
      end

      left_end = @doc.cursor
      @doc.bounding_box([col_w + 30, y], width: col_w) do
        section_label(I18n.t('dossier.description.location_header'))
        @doc.move_down 6
        render_kv_table(location_rows)
      end
      right_end = @doc.cursor

      @doc.move_cursor_to([left_end, right_end].min)
      @doc.move_down 18
    end

    def render_kv_table(rows)
      return if rows.empty?

      @doc.table(rows, cell_style: { borders: [:bottom], border_color: AuditPdf::Theme::HAIRLINE,
                                     padding: [6, 0], size: 10 },
                       width: @doc.bounds.width) do
        column(0).text_color = AuditPdf::Theme::INK_SOFT
        column(1).align = :right
        column(1).font_style = :bold
      end
    end

    def feature_rows
      rows = []
      area = @p.try(:area) || @p.try(:total_area)
      rows << [t('area'), fmt_area(area)] if area.present?

      living = @p.try(:living_area)
      rows << [t('living_area'), fmt_area(living)] if living.present? && living.to_f > 0

      kitchen = @p.try(:kitchen_area)
      rows << [t('kitchen_area'), fmt_area(kitchen)] if kitchen.present? && kitchen.to_f > 0

      rows << [t('rooms'), @p.rooms.to_s] if @p.try(:rooms).present?
      rows << [t('bedrooms'), @p.try(:bedrooms).to_s] if @p.try(:bedrooms).present? && @p.bedrooms.to_i > 0
      rows << [t('bathrooms'), @p.try(:bathrooms).to_s] if @p.try(:bathrooms).present? && @p.bathrooms.to_i > 0
      rows << [t('floor'), fmt_floor(@p.try(:floor), @p.try(:total_floors))] if @p.try(:floor).present?
      rows << [t('total_floors'), @p.total_floors.to_s] if @p.try(:total_floors).present? && @p.try(:floor).blank?
      rows << [t('building_year'), @p.building_year.to_s] if @p.try(:building_year).present?
      rows << [t('building_type'), @p.building_type.to_s] if @p.try(:building_type).present?
      rows << [t('condition'), condition_label(@p.try(:condition))] if @p.try(:condition).present?
      rows
    end

    def location_rows
      rows = []
      rows << [I18n.t('dossier.description.location.address'), @p.address.to_s.truncate(50)] if @p.try(:address).present?
      rows << [I18n.t('dossier.description.location.district'), @p.district.to_s] if @p.try(:district).present?
      rows << [I18n.t('dossier.description.location.metro'), @p.metro_station.to_s] if @p.try(:metro_station).present?
      if @p.try(:metro_distance).present? && @p.metro_distance.to_i > 0
        rows << [I18n.t('dossier.description.location.metro_distance'), "#{@p.metro_distance} мин"]
      end
      rows
    end

    def description_block
      desc = @p.try(:description).to_s.strip
      section_label(I18n.t('dossier.description.description_header'))
      @doc.move_down 6

      if desc.empty?
        @doc.fill_color AuditPdf::Theme::MUTED
        @doc.text I18n.t('dossier.description.no_description'), size: 10, leading: 2
        @doc.fill_color AuditPdf::Theme::INK
      else
        @doc.fill_color AuditPdf::Theme::INK_SOFT
        @doc.font(AuditPdf::Theme::FONT_FAMILY, style: :normal) do
          @doc.text desc.truncate(2500), size: 10, leading: 3, align: :justify
        end
        @doc.fill_color AuditPdf::Theme::INK
      end
    end

    def page_footer
      @doc.move_cursor_to(40)
      @doc.fill_color AuditPdf::Theme::MUTED
      @doc.text I18n.t('dossier.page_footer', page: 3, report: report_label),
                size: 7, align: :center
      @doc.fill_color AuditPdf::Theme::INK
    end

    def t(feature_key)
      I18n.t("dossier.description.features.#{feature_key}")
    end

    def fmt_area(v)
      return '—' if v.blank? || v.to_f.zero?
      "#{v.to_f.round(1)} м²"
    end

    def fmt_floor(floor, total)
      return '—' if floor.blank?
      total.present? ? "#{floor}/#{total}" : floor.to_s
    end

    # Property.condition (enum в БД integer-based, или string?) → human label
    def condition_label(condition)
      case condition.to_s
      when 'needs_repair' then 'требует ремонта'
      when 'normal'       then 'обычный ремонт'
      when 'renovated'    then 'свежий ремонт'
      when 'euro'         then 'евроремонт'
      when 'designer'     then 'дизайнерский'
      else                     condition.to_s
      end
    end

    def report_label
      @p.try(:slug) || "##{@p.id}"
    end
  end
end
