# frozen_string_literal: true

# Property Valuation Model
# Stores property valuation requests and results
class PropertyValuation < ApplicationRecord
  # Associations
  belongs_to :user, optional: true
  has_many_attached :photos
  
  # Enums
  enum property_type: {
    apartment: 'apartment',
    house: 'house',
    land: 'land',
    commercial: 'commercial',
    garage: 'garage',
    room: 'room'
  }
  
  enum deal_type: {
    sale: 'sale',
    rent: 'rent'
  }
  
  enum status: {
    pending: 'pending',
    completed: 'completed',
    failed: 'failed'
  }
  
  enum building_type: {
    panel: 'panel',
    brick: 'brick',
    monolith: 'monolith',
    block: 'block',
    wood: 'wood',
    stalin: 'stalin'
  }
  
  enum property_condition: {
    needs_repair: 'needs_repair',
    average: 'average',
    good: 'good',
    excellent: 'excellent',
    designer: 'designer'
  }, _prefix: :property_condition
  
  # Validations
  validates :property_type, presence: true
  validates :deal_type, presence: true
  validates :address, presence: true, length: { minimum: 10 }
  validates :total_area, presence: true, numericality: { greater_than: 0 }
  validates :floor, numericality: { greater_than: 0 }, allow_nil: true
  validates :total_floors, numericality: { greater_than: 0 }, allow_nil: true
  validates :rooms, numericality: { greater_than: 0 }, allow_nil: true
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validates :phone, format: { with: /\A\+?[0-9\s\-\(\)]+\z/ }, allow_blank: true
  validates :token, presence: true, uniqueness: true
  
  validate :floor_not_greater_than_total
  validate :photos_limit
  
  # Callbacks
  before_validation :generate_token, on: :create
  before_validation :normalize_phone
  
  # Scopes
  scope :recent, -> { order(created_at: :desc) }
  scope :completed, -> { where(status: 'completed') }
  scope :pending, -> { where(status: 'pending') }
  scope :with_email, -> { where.not(email: nil) }
  
  # Instance Methods
  
  def to_property_params
    {
      property_type: property_type,
      deal_type: deal_type,
      address: address,
      city: city,
      district: district,
      total_area: total_area,
      living_area: living_area,
      kitchen_area: kitchen_area,
      rooms: rooms,
      floor: floor,
      total_floors: total_floors,
      building_type: building_type,
      building_year: building_year,
      condition: condition,
      has_balcony: has_balcony,
      has_loggia: has_loggia,
      has_garage: has_garage,
      metro_station: metro_station,
      metro_distance: metro_distance
    }
  end
  
  def full_name
    name.presence || 'Неизвестный'
  end
  
  def price_range_formatted
    "#{ActionController::Base.helpers.number_to_currency(min_price, precision: 0)} - #{ActionController::Base.helpers.number_to_currency(max_price, precision: 0)}"
  end
  
  def estimated_price_formatted
    ActionController::Base.helpers.number_to_currency(estimated_price, precision: 0)
  end
  
  def confidence_percentage
    (confidence_level * 100).round
  end
  
  def accuracy_level
    case confidence_level
    when 0.8..1.0 then 'Высокая'
    when 0.6..0.8 then 'Средняя'
    else 'Низкая'
    end
  end
  
  def created_at_formatted
    I18n.l(created_at, format: :long)
  end
  
  private
  
  def generate_token
    self.token = SecureRandom.urlsafe_base64(16)
  end
  
  def normalize_phone
    return unless phone.present?
    
    # Remove all non-digit characters except +
    self.phone = phone.gsub(/[^\d+]/, '')
  end
  
  def floor_not_greater_than_total
    return unless floor.present? && total_floors.present?
    
    errors.add(:floor, 'не может быть больше общего количества этажей') if floor > total_floors
  end
  
  def photos_limit
    return unless photos.attached?
    
    if photos.count > 10
      errors.add(:photos, 'не может быть больше 10')
    end
    
    photos.each do |photo|
      if photo.byte_size > 5.megabytes
        errors.add(:photos, 'размер файла не должен превышать 5 МБ')
      end
      
      unless photo.content_type.in?(%w[image/jpeg image/png image/jpg image/webp])
        errors.add(:photos, 'должны быть в формате JPEG, PNG или WebP')
      end
    end
  end
end

