# frozen_string_literal: true

module CrmReports
  # One-page seller presentation: large block per selected property with
  # photo placeholder, key facts, and agency contact line. Designed for
  # 1-3 cards (anything bigger should use InventoryPdf instead).
  class SellerPresentation < Base
    MAX_PROPERTIES = 6

    def draw
      header(
        'Презентация объектов',
        "Подготовлено для клиента · #{Time.current.strftime('%d.%m.%Y')}"
      )

      properties = Property.unscoped.where(external_id: ids.map(&:to_s)).limit(MAX_PROPERTIES).to_a
      if properties.empty?
        pdf.text 'Объекты не найдены в базе.'
        footer
        return
      end

      properties.each_with_index do |p, idx|
        pdf.start_new_page if idx.positive?

        pdf.font_size 16
        pdf.text(p.title.to_s.presence || p.address.to_s)
        pdf.move_down 4
        pdf.font_size 10
        pdf.fill_color '666666'
        pdf.text(p.address.to_s)
        pdf.fill_color '000000'
        pdf.move_down 16

        pdf.font_size 24
        pdf.text "#{number(p.price)} ₽"
        pdf.font_size 11
        pdf.text "#{number(p.price_per_sqm.to_i)} ₽/м²" if p.price_per_sqm
        pdf.move_down 16

        pdf.font_size 10
        rows = [
          ['Площадь', "#{p.area} м²"],
          ['Комнат', p.rooms.to_s],
          ['Этаж', "#{p.floor} / #{p.total_floors}"],
          ['Год постройки', p.building_year.to_s],
          ['Состояние', p.condition.to_s.tr('_', ' ').capitalize],
          ['Район', p.district.to_s],
          ['Метро', p.metro_station.to_s]
        ].reject { |_, v| v.blank? }
        pdf.table(rows, width: pdf.bounds.width, cell_style: { size: 10, padding: [4, 6] }) do
          column(0).style font_style: :bold, background_color: 'f5f5f5'
        end

        if p.description.present?
          pdf.move_down 16
          pdf.font_size 10
          pdf.text p.description.to_s.gsub(/<\/?[^>]+>/, ' ').gsub(/\s+/, ' ').strip[0, 800]
        end
      end

      footer 'АН Виктори · viktory-realty.ru · +7 495 123-45-67'
    end
  end
end
