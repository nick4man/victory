# frozen_string_literal: true

class SavedSearch < ApplicationRecord
  # ============================================
  # ASSOCIATIONS
  # ============================================
  
  belongs_to :user
  
  # ============================================
  # VALIDATIONS
  # ============================================
  
  validates :search_params, presence: true
  
  # ============================================
  # SCOPES
  # ============================================
  
  scope :active, -> { where(active: true) }
  scope :inactive, -> { where(active: false) }
  scope :recent, -> { order(created_at: :desc) }
  scope :by_user, ->(user_id) { where(user_id: user_id) }
  
  # ============================================
  # SERIALIZATION
  # ============================================
  
  serialize :search_params, coder: JSON
  
  # ============================================
  # CALLBACKS
  # ============================================
  
  before_save :update_last_checked_at, if: :active?
  
  # ============================================
  # INSTANCE METHODS
  # ============================================
  
  # Get search parameters as hash
  def params_hash
    search_params.is_a?(Hash) ? search_params : {}
  end
  
  # Build query description from params
  def query_description
    parts = []
    params = params_hash
    
    parts << "Тип: #{params[:property_type]}" if params[:property_type].present?
    parts << "Сделка: #{params[:deal_type]}" if params[:deal_type].present?
    
    if params[:price_min].present? || params[:price_max].present?
      price_range = [params[:price_min], params[:price_max]].compact.join(' - ')
      parts << "Цена: #{price_range} ₽"
    end
    
    if params[:area_min].present? || params[:area_max].present?
      area_range = [params[:area_min], params[:area_max]].compact.join(' - ')
      parts << "Площадь: #{area_range} м²"
    end
    
    parts << "Комнат: #{params[:rooms]}" if params[:rooms].present?
    parts << "Район: #{params[:district]}" if params[:district].present?
    
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

