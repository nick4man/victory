# frozen_string_literal: true

require 'prawn'
require 'prawn/table'

# PDF Generator Service
# Generates PDF reports for property valuations
class PdfGeneratorService
  attr_reader :valuation, :pdf
  
  def initialize(valuation)
    @valuation = valuation
    @pdf = Prawn::Document.new(
      page_size: 'A4',
      page_layout: :portrait,
      margin: [50, 50, 50, 50]
    )
    
    setup_fonts
  end
  
  # Generate PDF and return as string
  def call
    draw_header
    draw_title
    draw_client_info
    draw_property_info
    draw_valuation_results
    draw_market_analysis
    draw_recommendations
    draw_footer
    
    pdf.render
  end
  
  # Save PDF to file
  def save_to_file(path)
    pdf.render_file(path)
  end
  
  private
  
  def setup_fonts
    # Register Russian font (using DejaVu Sans as it supports Cyrillic)
    font_path = Rails.root.join('app', 'assets', 'fonts')
    
    if File.exist?(font_path.join('DejaVuSans.ttf'))
      pdf.font_families.update(
        'DejaVuSans' => {
          normal: font_path.join('DejaVuSans.ttf').to_s,
          bold: font_path.join('DejaVuSans-Bold.ttf').to_s,
          italic: font_path.join('DejaVuSans-Oblique.ttf').to_s
        }
      )
      pdf.font 'DejaVuSans'
    else
      # Fallback to Prawn's built-in font (limited Cyrillic support)
      Rails.logger.warn 'DejaVu Sans font not found, using default font'
    end
  end
  
  def draw_header
    # Company logo and info
    pdf.bounding_box([0, pdf.cursor], width: pdf.bounds.width, height: 80) do
      pdf.text 'АН "Виктори"', size: 24, style: :bold, color: '667EEA'
      pdf.move_down 5
      pdf.text 'Агентство недвижимости', size: 12, color: '718096'
      pdf.move_down 5
      pdf.text "Телефон: #{ENV.fetch('CONTACT_PHONE', '+7 (999) 123-45-67')}", size: 10
      pdf.text "Email: #{ENV.fetch('CONTACT_EMAIL', 'info@viktory-realty.ru')}", size: 10
    end
    
    pdf.move_down 30
    pdf.stroke_horizontal_rule
    pdf.move_down 20
  end
  
  def draw_title
    pdf.text 'ОТЧЕТ ОБ ОЦЕНКЕ НЕДВИЖИМОСТИ', size: 18, style: :bold, align: :center
    pdf.move_down 5
    pdf.text "№ #{valuation.id} от #{I18n.l(valuation.created_at, format: :long)}", 
             size: 10, align: :center, color: '718096'
    pdf.move_down 20
  end
  
  def draw_client_info
    pdf.text 'ИНФОРМАЦИЯ О ЗАКАЗЧИКЕ', size: 14, style: :bold
    pdf.move_down 10
    
    data = [
      ['Имя:', valuation.name],
      ['Email:', valuation.email],
      ['Телефон:', valuation.phone],
      ['Дата заявки:', I18n.l(valuation.created_at, format: :long)]
    ]
    
    pdf.table(data, width: pdf.bounds.width, cell_style: { borders: [] }) do
      column(0).style(font_style: :bold, width: 120)
      column(1).style(width: pdf.bounds.width - 120)
    end
    
    pdf.move_down 20
  end
  
  def draw_property_info
    pdf.text 'ИНФОРМАЦИЯ ОБ ОБЪЕКТЕ', size: 14, style: :bold
    pdf.move_down 10
    
    data = [
      ['Адрес:', valuation.address],
      ['Тип недвижимости:', I18n.t("property_types.#{valuation.property_type}")],
      ['Площадь:', "#{valuation.area} м²"],
      ['Количество комнат:', valuation.rooms.to_s],
      ['Этаж:', "#{valuation.floor} из #{valuation.total_floors}"],
      ['Состояние:', I18n.t("property_conditions.#{valuation.condition}")]
    ]
    
    data << ['Год постройки:', valuation.year_built.to_s] if valuation.year_built.present?
    data << ['Метро:', "#{valuation.metro_station} (#{valuation.metro_distance} мин)"] if valuation.metro_station.present?
    
    pdf.table(data, width: pdf.bounds.width, cell_style: { borders: [] }) do
      column(0).style(font_style: :bold, width: 150)
      column(1).style(width: pdf.bounds.width - 150)
    end
    
    pdf.move_down 20
  end
  
  def draw_valuation_results
    pdf.text 'РЕЗУЛЬТАТЫ ОЦЕНКИ', size: 14, style: :bold
    pdf.move_down 10
    
    evaluation_data = JSON.parse(valuation.evaluation_data, symbolize_names: true)
    
    # Main price box
    pdf.bounding_box([0, pdf.cursor], width: pdf.bounds.width, height: 80) do
      pdf.fill_color 'F7FAFC'
      pdf.fill_rectangle [0, 80], pdf.bounds.width, 80
      pdf.fill_color '000000'
      
      pdf.move_down 15
      pdf.text 'РЫНОЧНАЯ СТОИМОСТЬ', size: 12, align: :center, color: '718096'
      pdf.move_down 5
      pdf.text format_price(valuation.estimated_price), 
               size: 24, style: :bold, align: :center, color: '667EEA'
      pdf.move_down 5
      pdf.text "от #{format_price(evaluation_data[:min_price])} до #{format_price(evaluation_data[:max_price])}", 
               size: 10, align: :center, color: '718096'
    end
    
    pdf.move_down 30
    
    # Price breakdown
    if evaluation_data[:base_price_per_sqm]
      pdf.text 'РАСЧЕТ СТОИМОСТИ', size: 12, style: :bold
      pdf.move_down 10
      
      breakdown_data = [
        ['Базовая цена за м²:', format_price(evaluation_data[:base_price_per_sqm])],
        ['Площадь:', "#{valuation.area} м²"],
        ['Базовая стоимость:', format_price(evaluation_data[:base_price])]
      ]
      
      if evaluation_data[:location_impact]
        impact = evaluation_data[:location_impact] > 0 ? "+#{evaluation_data[:location_impact].round(1)}%" : "#{evaluation_data[:location_impact].round(1)}%"
        breakdown_data << ['Корректировка по местоположению:', impact]
      end
      
      if evaluation_data[:condition_impact]
        impact = evaluation_data[:condition_impact] > 0 ? "+#{evaluation_data[:condition_impact].round(1)}%" : "#{evaluation_data[:condition_impact].round(1)}%"
        breakdown_data << ['Корректировка по состоянию:', impact]
      end
      
      if evaluation_data[:floor_impact]
        impact = evaluation_data[:floor_impact] > 0 ? "+#{evaluation_data[:floor_impact].round(1)}%" : "#{evaluation_data[:floor_impact].round(1)}%"
        breakdown_data << ['Корректировка по этажу:', impact]
      end
      
      if evaluation_data[:amenities_impact]
        impact = "+#{evaluation_data[:amenities_impact].round(1)}%"
        breakdown_data << ['Удобства и улучшения:', impact]
      end
      
      pdf.table(breakdown_data, width: pdf.bounds.width, cell_style: { borders: [] }) do
        column(0).style(font_style: :bold, width: 250)
        column(1).style(width: pdf.bounds.width - 250, align: :right)
      end
      
      pdf.move_down 20
    end
    
    # Confidence level
    if evaluation_data[:confidence_level]
      pdf.text "Достоверность оценки: #{evaluation_data[:confidence_level]}%", size: 10, color: '48BB78'
      pdf.move_down 20
    end
  end
  
  def draw_market_analysis
    evaluation_data = JSON.parse(valuation.evaluation_data, symbolize_names: true)
    
    return unless evaluation_data[:market_analysis]
    
    pdf.text 'АНАЛИЗ РЫНОЧНОЙ СИТУАЦИИ', size: 14, style: :bold
    pdf.move_down 10
    
    pdf.text evaluation_data[:market_analysis], size: 10, align: :justify, leading: 3
    
    pdf.move_down 20
  end
  
  def draw_recommendations
    evaluation_data = JSON.parse(valuation.evaluation_data, symbolize_names: true)
    
    return unless evaluation_data[:recommendations]&.any?
    
    pdf.text 'РЕКОМЕНДАЦИИ', size: 14, style: :bold
    pdf.move_down 10
    
    evaluation_data[:recommendations].each_with_index do |rec, index|
      pdf.text "#{index + 1}. #{rec[:title]}", size: 11, style: :bold
      pdf.move_down 3
      pdf.text rec[:description], size: 10
      
      if rec[:potential_gain]
        pdf.move_down 2
        pdf.text "Потенциальная выгода: #{format_price(rec[:potential_gain])}", 
                 size: 10, color: '48BB78', style: :italic
      end
      
      pdf.move_down 10
    end
  end
  
  def draw_footer
    pdf.move_down 30
    pdf.stroke_horizontal_rule
    pdf.move_down 10
    
    pdf.text 'ВАЖНАЯ ИНФОРМАЦИЯ', size: 10, style: :bold
    pdf.move_down 5
    pdf.text 'Данная оценка носит информационный характер и действительна в течение 30 дней с момента составления. ' \
             'Окончательная рыночная стоимость может отличаться в зависимости от текущей ситуации на рынке недвижимости.',
             size: 8, color: '718096', align: :justify
    
    pdf.move_down 10
    pdf.text "Отчет сформирован автоматически системой АН \"Виктори\" #{Time.current.strftime('%d.%m.%Y в %H:%M')}", 
             size: 8, color: 'A0AEC0', align: :center
    
    # Page numbers
    pdf.number_pages 'Страница <page> из <total>', 
                     at: [pdf.bounds.right - 150, 0],
                     width: 150,
                     align: :right,
                     size: 8,
                     color: 'A0AEC0'
  end
  
  def format_price(price)
    "#{price.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1 ').reverse} ₽"
  end
end

