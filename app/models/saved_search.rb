# frozen_string_literal: true

class SavedSearch < ApplicationRecord
  # ============================================
  # ASSOCIATIONS
  # ============================================
  
  belongs_to :user
  
  # ============================================
  # VALIDATIONS
  # ============================================
  
  validates :name, presence: true
  validates :filters, presence: true
  
  # ============================================
  # SCOPES
  # ============================================
  
  scope :active, -> { where(active: true) }
  scope :inactive, -> { where(active: false) }
  scope :recent, -> { order(created_at: :desc) }
  scope :by_user, ->(user_id) { where(user_id: user_id) }
  
  # ============================================
  # CALLBACKS
  # ============================================
  
  before_save :update_last_checked_at, if: :active?
  
  # ============================================
  # INSTANCE METHODS
  # ============================================
  
  # Get search parameters as hash
  def params_hash
    return filters if filters.is_a?(Hash)

    JSON.parse(filters.to_s)
  rescue JSON::ParserError, TypeError
    {}
  end
  
  # Build query description from params
  def query_description
    parts = []
    # params_hash returns JSONB data — keys are strings, not symbols
    p = params_hash.transform_keys(&:to_s)

    parts << "Тип: #{p['property_type']}" if p['property_type'].present?
    parts << "Сделка: #{p['deal_type']}" if p['deal_type'].present?

    if p['price_min'].present? || p['price_max'].present?
      price_range = [p['price_min'], p['price_max']].compact.join(' - ')
      parts << "Цена: #{price_range} ₽"
    end

    if p['area_min'].present? || p['area_max'].present?
      area_range = [p['area_min'], p['area_max']].compact.join(' - ')
      parts << "Площадь: #{area_range} м²"
    end

    parts << "Комнат: #{p['rooms']}" if p['rooms'].present?
    parts << "Район: #{p['district']}" if p['district'].present?

    parts.join(', ')
  end
  
  # Check for new results
  def check_new_results!
    # This would query properties with the saved search params
    # and compare with previously seen results
    update(last_checked_at: Time.current)
  end
  
  # Activate search
  def activate!
    update(active: true)
  end
  
  # Deactivate search
  def deactivate!
    update(active: false)
  end
  
  private
  
  def update_last_checked_at
    self.last_checked_at ||= Time.current
  end
end

