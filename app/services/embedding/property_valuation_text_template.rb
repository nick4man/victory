# frozen_string_literal: true

module Embedding
  # work_bot 2/3 — text template для embed'инга завершённой PropertyValuation
  # в gemini-embedding-001. Цель: semantic поиск похожих прошлых оценок —
  # «что мы оценивали похожим образом и за сколько».
  #
  # Включаем (параметры объекта + результат):
  #   • тип объекта, тип сделки — текстом
  #   • город, район
  #   • площадь, комнаты, этаж, состояние, год постройки
  #   • итоговая цена (или вилка min–max), ₽/м²
  #   • дата оценки (dd.MM.yy), число использованных аналогов
  #
  # ИСКЛЮЧАЕМ:
  #   • name, email, phone, ip_address — PII, для semantic match не нужны
  #   • address — идентифицирует человека; район+города достаточно
  #   • token, id, user_agent — noise
  module PropertyValuationTextTemplate
    PROPERTY_TYPE_LABELS = {
      'apartment'    => 'квартира',
      'house'        => 'дом',
      'land'         => 'участок',
      'commercial'   => 'коммерческая недвижимость',
      'garage'       => 'гараж',
      'room'         => 'комната'
    }.freeze

    DEAL_TYPE_LABELS = {
      'sale' => 'продажа',
      'rent' => 'аренда'
    }.freeze

    CONDITION_LABELS = {
      'needs_repair' => 'требует ремонта',
      'average'      => 'среднее',
      'good'         => 'хорошее',
      'excellent'    => 'отличное',
      'designer'     => 'дизайнерский ремонт'
    }.freeze

    def self.build(valuation)
      parts = []

      type_label = PROPERTY_TYPE_LABELS[valuation.property_type]
      parts << "Тип объекта: #{type_label}" if type_label.present?

      deal_label = DEAL_TYPE_LABELS[valuation.deal_type]
      parts << "Тип сделки: #{deal_label}" if deal_label.present?

      parts << "Город: #{valuation.city}" if valuation.city.present?
      parts << "Район: #{valuation.district}" if valuation.district.present?
      parts << "Площадь: #{valuation.total_area} м²" if valuation.total_area.present?
      parts << "Комнат: #{valuation.rooms}" if valuation.rooms.present?
      parts << "Этаж: #{valuation.floor} из #{valuation.total_floors}" if valuation.floor.present? && valuation.total_floors.present?
      parts << "Этаж: #{valuation.floor}" if valuation.floor.present? && valuation.total_floors.blank?

      condition_label = CONDITION_LABELS[valuation.property_condition]
      parts << "Состояние: #{condition_label}" if condition_label.present?
      parts << "Год постройки: #{valuation.building_year}" if valuation.building_year.present?

      append_price(parts, valuation)
      append_price_per_sqm(parts, valuation)

      parts << "Дата оценки: #{valuation.updated_at.strftime('%d.%m.%y')}"

      analogs = analogs_count(valuation)
      parts << "Использовано аналогов: #{analogs}" if analogs.positive?

      parts.join("\n").truncate(2000)
    end

    def self.append_price(parts, valuation)
      if valuation.estimated_price.present?
        parts << "Итоговая цена оценки: #{format_price(valuation.estimated_price)} ₽"
      elsif valuation.min_price.present? && valuation.max_price.present?
        parts << "Вилка оценки: #{format_price(valuation.min_price)} - #{format_price(valuation.max_price)} ₽"
      end
    end

    def self.append_price_per_sqm(parts, valuation)
      return unless valuation.estimated_price.present? && valuation.total_area.to_f.positive?

      parts << "Цена за м²: #{format_price(valuation.estimated_price.to_f / valuation.total_area.to_f)} ₽"
    end

    def self.analogs_count(valuation)
      data = valuation.evaluation_data || {}
      comps = data['comparables']
      return comps.size if comps.is_a?(Array)

      data['candidates_kept'].to_i
    end

    def self.format_price(value)
      ActionController::Base.helpers.number_with_delimiter(value.round, delimiter: ' ')
    end
  end
end
