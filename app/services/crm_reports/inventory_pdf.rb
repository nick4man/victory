# frozen_string_literal: true

module CrmReports
  # Generates a tabular PDF inventory of selected Topnlab realty cards.
  # Used as default report on /menu/create with template_class='CrmReports::InventoryPdf'.
  class InventoryPdf < Base
    MAX_ROWS = 50

    def draw
      header(
        report&.title.presence || 'Подборка объектов',
        "Сформировано для #{user_label} · #{Time.current.strftime('%d.%m.%Y %H:%M')}"
      )

      properties = Property.unscoped.where(external_id: ids.map(&:to_s)).limit(MAX_ROWS).to_a
      if properties.empty?
        pdf.text 'По выбранным ID объекты не найдены в локальной базе.'
        footer
        return
      end

      table_data = [['#', 'Адрес', 'Площадь', 'Цена', 'Тип']]
      properties.each_with_index do |p, i|
        table_data << [
          (i + 1).to_s,
          (p.address.to_s.length > 60 ? "#{p.address.to_s[0, 57]}..." : p.address.to_s),
          "#{p.area} м²",
          "#{number(p.price)} ₽",
          p.property_type&.name || p.try(:realty_type) || '—'
        ]
      end

      pdf.table(table_data, header: true, width: pdf.bounds.width,
                cell_style: { size: 9, padding: [4, 6] }) do
        row(0).font_style = :bold
        row(0).background_color = 'eeeeee'
      end

      pdf.move_down 16
      pdf.font_size 9
      pdf.text "Объектов в подборке: #{properties.size}#{ids.size > properties.size ? " из #{ids.size} запрошенных" : ''}"
      pdf.text "Суммарная стоимость: #{number(properties.sum { |p| p.price.to_i })} ₽"

      footer
    end

    private

    def user_label
      [user['lastname'], user['firstname']].compact.reject(&:blank?).join(' ').presence || user['email'].to_s.presence || 'агента'
    end
  end
end
