# frozen_string_literal: true

# == Schema Information
#
# Table name: price_histories
#
#  id                   :bigint           not null, primary key
#  property_id          :bigint           not null
#  changed_by_id        :bigint
#  old_price            :decimal(15, 2)
#  new_price            :decimal(15, 2)   not null
#  price_change         :decimal(15, 2)
#  price_change_percent :decimal(5, 2)
#  change_type          :string           not null
#  reason               :text
#  notes                :text
#  effective_date       :datetime         not null
#  auto_generated       :boolean          default(FALSE), not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#

class PriceHistory < ApplicationRecord
  # ============================================
  # ASSOCIATIONS
  # ============================================
  
  belongs_to :property
  belongs_to :changed_by, class_name: 'User', optional: true
  
  # ============================================
  # ENUMS
  # ============================================
  
  enum change_type: {
    increase: 'increase',
    decrease: 'decrease'
  }, _prefix: true
  
  # ============================================
  # VALIDATIONS
  # ============================================
  
  validates :new_price, presence: true, numericality: { greater_than: 0 }
  validates :change_type, presence: true
  validates :effective_date, presence: true
  
  validate :price_change_valid
  
  # ============================================
  # CALLBACKS
  # ============================================
  
  before_validation :calculate_price_changes, if: :new_price_changed?
  before_validation :set_effective_date, unless: :effective_date?
  after_create :update_property_price
  
  # ============================================
  # SCOPES
  # ============================================
  
  scope :recent, -> { order(effective_date: :desc) }
  scope :chronological, -> { order(effective_date: :asc) }
  scope :increases, -> { where(change_type: 'increase') }
  scope :decreases, -> { where(change_type: 'decrease') }
  scope :manual, -> { where(auto_generated: false) }
  scope :automatic, -> { where(auto_generated: true) }
  scope :in_date_range, ->(start_date, end_date) { 
    where(effective_date: start_date..end_date) 
  }
  scope :since, ->(date) { where('effective_date >= ?', date) }
  scope :by_property, ->(property_id) { where(property_id: property_id) }
  
  # ============================================
  # CLASS METHODS
  # ============================================
  
  # Record a price change
  def self.record_change(property:, new_price:, changed_by: nil, reason: nil, notes: nil, effective_date: nil)
    create(
      property: property,
      old_price: property.price,
      new_price: new_price,
      changed_by: changed_by,
      reason: reason,
      notes: notes,
      effective_date: effective_date || Time.current,
      auto_generated: changed_by.nil?
    )
  end
  
  # Get price at specific date
  def self.price_at_date(property_id, date)
    where(property_id: property_id)
      .where('effective_date <= ?', date)
      .order(effective_date: :desc)
      .first
      &.new_price
  end
  
  # Calculate average price change
  def self.average_price_change
    return 0 if none?
    average(:price_change)
  end
  
  # Calculate average price change percent
  def self.average_price_change_percent
    return 0 if none?
    average(:price_change_percent)
  end
  
  # ============================================
  # INSTANCE METHODS
  # ============================================
  
  # Formatted old price
  def old_price_formatted
    return 'N/A' unless old_price.present?
    ActionController::Base.helpers.number_to_currency(
      old_price,
      unit: '₽',
      separator: ',',
      delimiter: ' ',
      format: '%n %u'
    )
  end
  
  # Formatted new price
  def new_price_formatted
    return 'N/A' unless new_price.present?
    ActionController::Base.helpers.number_to_currency(
      new_price,
      unit: '₽',
      separator: ',',
      delimiter: ' ',
      format: '%n %u'
    )
  end
  
  # Formatted price change
  def price_change_formatted
    return 'N/A' unless price_change.present?
    
    sign = price_change > 0 ? '+' : ''
    "#{sign}#{ActionController::Base.helpers.number_to_currency(
      price_change,
      unit: '₽',
      separator: ',',
      delimiter: ' ',
      format: '%n %u'
    )}"
  end
  
  # Price change percent formatted
  def price_change_percent_formatted
    return 'N/A' unless price_change_percent.present?
    
    sign = price_change_percent > 0 ? '+' : ''
    "#{sign}#{price_change_percent}%"
  end
  
  # Change type humanized
  def change_type_humanized
    I18n.t("activerecord.attributes.price_history.change_types.#{change_type}", default: change_type.humanize)
  end
  
  # Icon for change type
  def change_icon
    case change_type
    when 'increase'
      '↑'
    when 'decrease'
      '↓'
    else
      '='
    end
  end
  
  # Color class for UI
  def change_color_class
    case change_type
    when 'increase'
      'text-red-600'
    when 'decrease'
      'text-green-600'
    else
      'text-gray-600'
    end
  end
  
  # Check if significant change (more than 5%)
  def significant_change?
    return false unless price_change_percent.present?
    price_change_percent.abs >= 5
  end
  
  private
  
  # ============================================
  # VALIDATIONS
  # ============================================
  
  def price_change_valid
    return unless old_price.present? && new_price.present?
    
    if old_price == new_price
      errors.add(:new_price, 'должна отличаться от старой')
    end
  end
  
  # ============================================
  # CALLBACKS
  # ============================================
  
  def calculate_price_changes
    return unless new_price.present?
    
    # Set old price from property if not set
    self.old_price ||= property&.price
    
    # Calculate price change
    if old_price.present?
      self.price_change = new_price - old_price
      
      # Calculate percentage
      if old_price > 0
        self.price_change_percent = ((price_change / old_price) * 100).round(2)
      end
      
      # Set change type
      self.change_type = price_change >= 0 ? 'increase' : 'decrease'
    else
      self.price_change = 0
      self.price_change_percent = 0
      self.change_type = 'increase'
    end
  end
  
  def set_effective_date
    self.effective_date = Time.current
  end
  
  def update_property_price
    property.update_column(:price, new_price) if property.present?
  end
end

