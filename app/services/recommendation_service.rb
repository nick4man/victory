# frozen_string_literal: true

# Recommendation Service
# Provides personalized property recommendations based on user behavior
class RecommendationService
  attr_reader :user, :limit
  
  def initialize(user, limit: 10)
    @user = user
    @limit = limit
  end
  
  # Get personalized recommendations
  def call
    return Property.active.limit(limit) unless user
    
    recommendations = []
    
    # 1. Based on favorites (collaborative filtering)
    recommendations.concat(recommendations_from_favorites)
    
    # 2. Based on search history
    recommendations.concat(recommendations_from_searches)
    
    # 3. Based on viewed properties
    recommendations.concat(recommendations_from_views)
    
    # 4. Based on inquiries
    recommendations.concat(recommendations_from_inquiries)
    
    # 5. Fill with popular properties if needed
    recommendations.concat(popular_properties) if recommendations.size < limit
    
    # Remove duplicates and limit
    Property.where(id: recommendations.map(&:id).uniq).limit(limit)
  end
  
  # Get similar properties to a specific property
  def similar_to(property)
    return Property.none unless property
    
    Property.active
            .where(property_type: property.property_type)
            .where(deal_type: property.deal_type)
            .where('price BETWEEN ? AND ?', property.price * 0.8, property.price * 1.2)
            .where('area BETWEEN ? AND ?', property.area * 0.8, property.area * 1.2)
            .where.not(id: property.id)
            .order(Arel.sql('RANDOM()'))
            .limit(limit)
  end
  
  # Get properties matching user's saved search criteria
  def from_saved_search(saved_search)
    return Property.none unless saved_search
    
    criteria = saved_search.criteria
    scope = Property.active
    
    scope = scope.where(property_type: criteria['property_type']) if criteria['property_type'].present?
    scope = scope.where(deal_type: criteria['deal_type']) if criteria['deal_type'].present?
    scope = scope.where('price >= ?', criteria['min_price']) if criteria['min_price'].present?
    scope = scope.where('price <= ?', criteria['max_price']) if criteria['max_price'].present?
    scope = scope.where('area >= ?', criteria['min_area']) if criteria['min_area'].present?
    scope = scope.where('area <= ?', criteria['max_area']) if criteria['max_area'].present?
    scope = scope.where('rooms >= ?', criteria['min_rooms']) if criteria['min_rooms'].present?
    scope = scope.where(district: criteria['district']) if criteria['district'].present?
    
    scope.order(created_at: :desc).limit(limit)
  end
  
  # Get new properties matching user preferences
  def new_arrivals
    return Property.active.order(created_at: :desc).limit(limit) unless user
    
    preferences = extract_user_preferences
    
    scope = Property.active
    scope = scope.where(property_type: preferences[:property_types]) if preferences[:property_types].any?
    scope = scope.where(deal_type: preferences[:deal_types]) if preferences[:deal_types].any?
    
    if preferences[:price_range][:min] && preferences[:price_range][:max]
      scope = scope.where(price: preferences[:price_range][:min]..preferences[:price_range][:max])
    end
    
    scope.order(created_at: :desc).limit(limit)
  end
  
  # Get price reduced properties
  def price_reductions
    Property.active
            .where('EXISTS (SELECT 1 FROM property_price_histories WHERE property_id = properties.id AND old_price > new_price)')
            .order(updated_at: :desc)
            .limit(limit)
  end
  
  private
  
  # Recommendations based on user's favorite properties
  def recommendations_from_favorites
    return [] unless user.favorites.any?
    
    favorite_ids = user.favorites.pluck(:property_id)
    favorite_properties = Property.where(id: favorite_ids)
    
    # Get similar properties
    similar_properties = []
    favorite_properties.each do |property|
      similar_properties.concat(similar_to(property).to_a)
    end
    
    similar_properties.uniq
  end
  
  # Recommendations based on search history
  def recommendations_from_searches
    return [] unless user.saved_searches.any?
    
    recent_search = user.saved_searches.order(created_at: :desc).first
    from_saved_search(recent_search).to_a
  end
  
  # Recommendations based on viewed properties
  def recommendations_from_views
    return [] unless user.property_views.any?
    
    viewed_ids = user.property_views.order(created_at: :desc).limit(20).pluck(:property_id)
    viewed_properties = Property.where(id: viewed_ids)
    
    # Get properties with similar characteristics
    similar_properties = []
    viewed_properties.first(3).each do |property|
      similar_properties.concat(similar_to(property).to_a)
    end
    
    similar_properties.uniq
  end
  
  # Recommendations based on inquiries
  def recommendations_from_inquiries
    return [] unless user.inquiries.any?
    
    inquiry_property_ids = user.inquiries.where.not(property_id: nil).pluck(:property_id)
    return [] if inquiry_property_ids.empty?
    
    inquiry_properties = Property.where(id: inquiry_property_ids)
    
    similar_properties = []
    inquiry_properties.each do |property|
      similar_properties.concat(similar_to(property).to_a)
    end
    
    similar_properties.uniq
  end
  
  # Popular properties as fallback
  def popular_properties
    Property.active
            .order(views_count: :desc, created_at: :desc)
            .limit(limit)
            .to_a
  end
  
  # Extract user preferences from history
  def extract_user_preferences
    preferences = {
      property_types: [],
      deal_types: [],
      price_range: { min: nil, max: nil },
      districts: []
    }
    
    # From favorites
    if user.favorites.any?
      favorite_properties = Property.where(id: user.favorites.pluck(:property_id))
      preferences[:property_types].concat(favorite_properties.pluck(:property_type))
      preferences[:deal_types].concat(favorite_properties.pluck(:deal_type))
      
      prices = favorite_properties.pluck(:price)
      if prices.any?
        avg_price = prices.sum / prices.size
        preferences[:price_range][:min] = (avg_price * 0.7).to_i
        preferences[:price_range][:max] = (avg_price * 1.3).to_i
      end
    end
    
    # From searches
    if user.saved_searches.any?
      user.saved_searches.each do |search|
        criteria = search.criteria
        preferences[:property_types] << criteria['property_type'] if criteria['property_type'].present?
        preferences[:deal_types] << criteria['deal_type'] if criteria['deal_type'].present?
        preferences[:districts] << criteria['district'] if criteria['district'].present?
      end
    end
    
    # From views
    if user.property_views.any?
      viewed_properties = Property.where(id: user.property_views.limit(20).pluck(:property_id))
      preferences[:property_types].concat(viewed_properties.pluck(:property_type))
      preferences[:deal_types].concat(viewed_properties.pluck(:deal_type))
    end
    
    # Clean up and deduplicate
    preferences[:property_types].uniq!
    preferences[:deal_types].uniq!
    preferences[:districts].uniq!
    
    preferences
  end
end
