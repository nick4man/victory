# frozen_string_literal: true

# Property Evaluation Service
# Calculates property market value based on multiple factors
class PropertyEvaluationService
  attr_reader :valuation, :result
  
  # Initialize service with valuation record
  def initialize(valuation)
    @valuation = valuation
    @result = {}
  end
  
  # Main evaluation method
  def call
    return error_result('Invalid valuation data') unless valid_input?
    
    calculate_base_price
    apply_location_coefficient
    apply_condition_coefficient
    apply_floor_coefficient
    apply_amenities_coefficient
    calculate_price_range
    generate_market_analysis
    generate_recommendations
    
    success_result
  rescue StandardError => e
    Rails.logger.error "Property evaluation failed: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    error_result("Evaluation error: #{e.message}")
  end
  
  private
  
  def valid_input?
    valuation.present? &&
      valuation.area.to_f > 0 &&
      valuation.property_type.present? &&
      valuation.address.present?
  end
  
  # Calculate base price using average market price per sqm
  def calculate_base_price
    @base_price_per_sqm = get_base_price_per_sqm
    @base_price = @base_price_per_sqm * valuation.area.to_f
    
    @result[:base_price] = @base_price
    @result[:base_price_per_sqm] = @base_price_per_sqm
  end
  
  # Get average price per sqm for property type
  def get_base_price_per_sqm
    # In production, this should query real market data
    # For now, using average Moscow prices (2024)
    prices = {
      'apartment' => 250_000,
      'house' => 180_000,
      'townhouse' => 200_000,
      'land' => 50_000,
      'commercial' => 300_000,
      'garage' => 80_000
    }
    
    prices[valuation.property_type] || 200_000
  end
  
  # Apply location coefficient based on district/address
  def apply_location_coefficient
    @location_coefficient = calculate_location_coefficient
    @base_price *= @location_coefficient
    
    @result[:location_coefficient] = @location_coefficient
    @result[:location_impact] = (@location_coefficient - 1.0) * 100
  end
  
  def calculate_location_coefficient
    # Extract district/area from address
    address_lower = valuation.address.downcase
    
    # Premium locations
    return 1.5 if address_lower.match?(/центр|арбат|патриаршие|остоженка|пресня/)
    
    # Above average locations
    return 1.25 if address_lower.match?(/хамовники|замоскворечье|якиманка|тверская/)
    
    # Good locations
    return 1.1 if address_lower.match?(/сокол|аэропорт|крылатское|строгино/)
    
    # Average locations
    return 0.95 if address_lower.match?(/бирюлево|марьино|братеево|капотня/)
    
    # Default - average
    1.0
  end
  
  # Apply condition coefficient
  def apply_condition_coefficient
    @condition_coefficient = get_condition_coefficient
    @base_price *= @condition_coefficient
    
    @result[:condition_coefficient] = @condition_coefficient
    @result[:condition_impact] = (@condition_coefficient - 1.0) * 100
  end
  
  def get_condition_coefficient
    case valuation.condition
    when 'excellent', 'euro_renovation'
      1.15
    when 'good', 'modern_renovation'
      1.05
    when 'satisfactory', 'cosmetic_renovation'
      0.95
    when 'needs_renovation'
      0.80
    else
      1.0
    end
  end
  
  # Apply floor coefficient
  def apply_floor_coefficient
    return unless valuation.floor.present? && valuation.total_floors.present?
    
    @floor_coefficient = calculate_floor_coefficient
    @base_price *= @floor_coefficient
    
    @result[:floor_coefficient] = @floor_coefficient
    @result[:floor_impact] = (@floor_coefficient - 1.0) * 100
  end
  
  def calculate_floor_coefficient
    floor = valuation.floor.to_i
    total = valuation.total_floors.to_i
    
    # First floor penalty
    return 0.92 if floor == 1 && total > 1
    
    # Last floor bonus/penalty depending on building type
    if floor == total
      # Bonus for low buildings (penthouse effect)
      return 1.08 if total <= 5
      
      # Penalty for high buildings
      return 0.95 if total > 16
    end
    
    # Middle floors are optimal
    middle_start = [total / 4, 3].max
    middle_end = (total * 3 / 4).ceil
    
    return 1.03 if floor.between?(middle_start, middle_end)
    
    1.0
  end
  
  # Apply amenities coefficient
  def apply_amenities_coefficient
    return unless valuation.amenities.present?
    
    @amenities_coefficient = calculate_amenities_coefficient
    @base_price *= @amenities_coefficient
    
    @result[:amenities_coefficient] = @amenities_coefficient
    @result[:amenities_impact] = (@amenities_coefficient - 1.0) * 100
  end
  
  def calculate_amenities_coefficient
    bonus = 0.0
    
    amenities = valuation.amenities
    
    # Major amenities
    bonus += 0.05 if amenities.include?('parking')
    bonus += 0.03 if amenities.include?('balcony')
    bonus += 0.04 if amenities.include?('furniture')
    
    # Building amenities
    bonus += 0.02 if amenities.include?('elevator')
    bonus += 0.02 if amenities.include?('security')
    bonus += 0.02 if amenities.include?('concierge')
    
    # Luxury amenities
    bonus += 0.03 if amenities.include?('gym')
    bonus += 0.03 if amenities.include?('pool')
    
    1.0 + [bonus, 0.20].min # Cap at 20% bonus
  end
  
  # Calculate price range (min/max)
  def calculate_price_range
    # Market volatility factor: ±10%
    @result[:estimated_price] = @base_price.round(-3)
    @result[:min_price] = (@base_price * 0.90).round(-3)
    @result[:max_price] = (@base_price * 1.10).round(-3)
    @result[:confidence_level] = calculate_confidence_level
  end
  
  def calculate_confidence_level
    # Higher confidence for more complete data
    confidence = 70
    
    confidence += 10 if valuation.floor.present?
    confidence += 10 if valuation.amenities.present?
    confidence += 5 if valuation.year_built.present?
    confidence += 5 if valuation.metro_station.present?
    
    [confidence, 95].min
  end
  
  # Generate market analysis text
  def generate_market_analysis
    analysis = []
    
    # Price trend
    analysis << "Текущая рыночная ситуация благоприятна для #{valuation_for_deal}. "
    
    # Location analysis
    if @location_coefficient > 1.1
      analysis << 'Локация объекта относится к престижному району, что повышает его стоимость. '
    elsif @location_coefficient < 0.95
      analysis << 'Расположение в развивающемся районе позволяет предложить конкурентную цену. '
    end
    
    # Condition analysis
    if @condition_coefficient > 1.05
      analysis << 'Отличное состояние объекта положительно влияет на оценку. '
    elsif @condition_coefficient < 0.90
      analysis << 'Необходимость ремонта учтена в цене. '
    end
    
    # Area analysis
    area_per_room = valuation.rooms.present? ? valuation.area.to_f / valuation.rooms.to_i : 0
    if area_per_room > 25
      analysis << 'Просторные комнаты являются преимуществом объекта. '
    end
    
    # Market demand
    analysis << generate_demand_forecast
    
    @result[:market_analysis] = analysis.join
  end
  
  def valuation_for_deal
    case valuation.deal_type
    when 'sale'
      'продажи'
    when 'rent'
      'сдачи в аренду'
    else
      'сделки'
    end
  end
  
  def generate_demand_forecast
    season = Date.current.month
    
    if season.in?([3, 4, 5, 9, 10])
      'Текущий сезон характеризуется повышенным спросом на недвижимость.'
    elsif season.in?([6, 7, 8])
      'Летний период обычно показывает умеренную активность на рынке.'
    else
      'Зимний период может потребовать гибкости в ценообразовании.'
    end
  end
  
  # Generate recommendations for seller
  def generate_recommendations
    recommendations = []
    
    # Pricing recommendations
    if @condition_coefficient < 0.95
      recommendations << {
        type: 'renovation',
        priority: 'high',
        title: 'Рекомендуем косметический ремонт',
        description: 'Небольшие вложения в ремонт могут увеличить стоимость на 10-15%',
        potential_gain: (@base_price * 0.125).round(-3)
      }
    end
    
    # Staging recommendations
    if valuation.amenities.blank? || valuation.amenities.size < 3
      recommendations << {
        type: 'staging',
        priority: 'medium',
        title: 'Рассмотрите стейджинг',
        description: 'Профессиональная подготовка квартиры к продаже ускорит сделку',
        potential_gain: nil
      }
    end
    
    # Photography recommendations
    recommendations << {
      type: 'photography',
      priority: 'high',
      title: 'Профессиональная фотосъемка',
      description: 'Качественные фото увеличивают количество просмотров на 60%',
      potential_gain: nil
    }
    
    # Documentation recommendations
    recommendations << {
      type: 'documents',
      priority: 'high',
      title: 'Подготовьте документы заранее',
      description: 'Готовый пакет документов ускоряет сделку на 2-3 недели',
      potential_gain: nil
    }
    
    # Marketing recommendations
    recommendations << {
      type: 'marketing',
      priority: 'medium',
      title: 'Комплексное продвижение',
      description: 'Размещение на топовых площадках + соцсети увеличит поток клиентов',
      potential_gain: nil
    }
    
    @result[:recommendations] = recommendations
  end
  
  def success_result
    {
      success: true,
      data: @result
    }
  end
  
  def error_result(message)
    {
      success: false,
      error: message
    }
  end
end
