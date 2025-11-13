# frozen_string_literal: true

class PropertyType < ApplicationRecord
  # ============================================
  # ASSOCIATIONS
  # ============================================
  
  has_many :properties, dependent: :restrict_with_error
  
  # ============================================
  # VALIDATIONS
  # ============================================
  
  validates :name, presence: true, uniqueness: true
  validates :slug, presence: true, uniqueness: true
  
  # ============================================
  # SCOPES
  # ============================================
  
  scope :active, -> { where(active: true) }
  scope :ordered_by_name, -> { order(name: :asc) }
  scope :ordered_by_position, -> { order(position: :asc) }
  
  # ============================================
  # CALLBACKS
  # ============================================
  
  before_validation :generate_slug, if: -> { name.present? && slug.blank? }
  
  # ============================================
  # CLASS METHODS
  # ============================================
  
  def self.for_select
    active.ordered_by_position.pluck(:name, :id)
  end
  
  # ============================================
  # INSTANCE METHODS
  # ============================================
  
  # Properties count
  def properties_count
    properties.count
  end
  
  # Active properties count
  def active_properties_count
    properties.active.count
  end
  
  private
  
  def generate_slug
    self.slug = name.parameterize
  end
end

