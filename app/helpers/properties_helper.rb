# frozen_string_literal: true

# Properties Helper
# Helper methods for property views
module PropertiesHelper
  # Property card classes
  def property_card_classes
    'bg-white rounded-lg shadow-md overflow-hidden hover:shadow-xl transition-shadow duration-300'
  end
  
  # Property features list
  def property_features(property)
    features = []
    
    features << "#{property.rooms} #{pluralize_russian(property.rooms, 'комната', 'комнаты', 'комнат')}" if property.rooms.present?
    features << format_area(property.area) if property.area.present?
    features << "#{property.floor}/#{property.total_floors} этаж" if property.floor.present?
    
    safe_join(features, content_tag(:span, ' • ', class: 'text-gray-400'))
  end
  
  # Property amenities icons
  def amenities_with_icons(amenities)
    return '' if amenities.blank?
    
    icons = {
      'parking' => '🚗',
      'elevator' => '🛗',
      'balcony' => '🏖️',
      'furniture' => '🛋️',
      'appliances' => '🔌',
      'internet' => '📶',
      'security' => '🔒',
      'playground' => '🎮',
      'concierge' => '👨‍💼',
      'gym' => '💪',
      'pool' => '🏊',
      'sauna' => '🧖'
    }
    
    content_tag(:div, class: 'flex flex-wrap gap-2') do
      amenities.map do |amenity|
        icon = icons[amenity] || '✓'
        text = I18n.t("amenities.#{amenity}", default: amenity.humanize)
        
        content_tag(:span, "#{icon} #{text}", class: 'inline-flex items-center px-3 py-1 rounded-full text-sm bg-gray-100 text-gray-700')
      end.inject(:+)
    end
  end
  
  # Property price per sqm
  def price_per_sqm(property)
    return '—' if property.price.blank? || property.area.blank? || property.area.zero?
    
    price_per_sqm = (property.price / property.area).round
    "#{format_price(price_per_sqm)}/м²"
  end
  
  # Metro distance badge
  def metro_badge(property)
    return nil unless property.metro_station.present?
    
    color = if property.metro_distance.to_i <= 5
              'bg-green-100 text-green-800'
            elsif property.metro_distance.to_i <= 10
              'bg-yellow-100 text-yellow-800'
            else
              'bg-gray-100 text-gray-800'
            end
    
    content_tag(:span, class: "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium #{color}") do
      "🚇 #{property.metro_station} • #{property.metro_distance} мин"
    end
  end
  
  # Property gallery
  def property_gallery(property, limit: nil)
    images = property.images.limit(limit)
    
    return nil if images.empty?
    
    content_tag(:div, class: 'grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-4') do
      images.map do |image|
        content_tag(:div, class: 'relative aspect-square overflow-hidden rounded-lg') do
          image_tag(image.url, class: 'w-full h-full object-cover hover:scale-110 transition-transform duration-300', alt: property.title)
        end
      end.inject(:+)
    end
  end
  
  # Property comparison button
  def add_to_comparison_button(property, classes: '')
    button_to 'Добавить к сравнению', 
              compare_properties_path(property_id: property.id), 
              method: :post,
              class: "#{classes} inline-flex items-center text-sm text-gray-600 hover:text-gray-900",
              form: { data: { turbo: false } } do
      safe_join([
        content_tag(:span, '📊', class: 'mr-1'),
        'Сравнить'
      ])
    end
  end
  
  # Add to favorites button
  def add_to_favorites_button(property, user, classes: '')
    return nil unless user
    
    is_favorite = user.favorites.exists?(property_id: property.id)
    
    if is_favorite
      button_to favorites_path(property_id: property.id), 
                method: :delete,
                class: "#{classes} inline-flex items-center text-sm text-red-600 hover:text-red-700",
                form: { data: { turbo: false } } do
        safe_join([
          content_tag(:span, '❤️', class: 'mr-1'),
          'В избранном'
        ])
      end
    else
      button_to favorites_path(property_id: property.id), 
                method: :post,
                class: "#{classes} inline-flex items-center text-sm text-gray-600 hover:text-gray-900",
                form: { data: { turbo: false } } do
        safe_join([
          content_tag(:span, '🤍', class: 'mr-1'),
          'В избранное'
        ])
      end
    end
  end
  
  # Property contact button
  def property_contact_button(property, text: 'Связаться', classes: '')
    link_to text,
            '#',
            class: "#{classes} inline-flex items-center justify-center px-6 py-3 bg-gradient-to-r from-purple-600 to-pink-600 text-white font-semibold rounded-lg hover:from-purple-700 hover:to-pink-700 transition-all",
            data: {
              controller: 'modal',
              action: 'click->modal#open',
              modal_target: 'trigger',
              property_id: property.id
            }
  end
  
  # Property view counter
  def property_views(property)
    views_count = property.views_count || 0
    
    content_tag(:span, class: 'inline-flex items-center text-sm text-gray-600') do
      safe_join([
        content_tag(:span, '👁️', class: 'mr-1'),
        number_with_delimiter(views_count, delimiter: ' ')
      ])
    end
  end
  
  # Property published date
  def property_published_date(property)
    return '—' unless property.created_at
    
    days_ago = (Date.current - property.created_at.to_date).to_i
    
    text = if days_ago.zero?
             'Сегодня'
           elsif days_ago == 1
             'Вчера'
           elsif days_ago < 7
             "#{days_ago} #{pluralize_russian(days_ago, 'день', 'дня', 'дней')} назад"
           else
             format_date(property.created_at, format: :short)
           end
    
    content_tag(:span, text, class: 'text-sm text-gray-600')
  end
  
  # Property floor info with validation
  def floor_info(property)
    return '—' unless property.floor.present?
    
    floor_class = if property.floor == 1
                    'text-yellow-600' # First floor
                  elsif property.floor == property.total_floors
                    'text-orange-600' # Last floor
                  else
                    'text-gray-700'
                  end
    
    content_tag(:span, "#{property.floor}/#{property.total_floors}", class: "font-medium #{floor_class}")
  end
  
  # Property deal type icon
  def deal_type_icon(type)
    case type
    when 'sale'
      '💰'
    when 'rent'
      '🔑'
    when 'rent_daily'
      '📅'
    else
      '🏠'
    end
  end
  
  private
  
  # Russian pluralization helper
  def pluralize_russian(count, one, few, many)
    count = count.to_i
    
    return many if (count % 100).between?(11, 14)
    
    case count % 10
    when 1
      one
    when 2..4
      few
    else
      many
    end
  end
end

