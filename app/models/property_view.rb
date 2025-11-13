# frozen_string_literal: true

class PropertyView < ApplicationRecord
  # ============================================
  # ASSOCIATIONS
  # ============================================
  
  belongs_to :property, counter_cache: :views_count
  belongs_to :user, optional: true
  
  # ============================================
  # SCOPES
  # ============================================
  
  scope :recent, -> { order(created_at: :desc) }
  scope :by_user, ->(user_id) { where(user_id: user_id) }
  scope :by_property, ->(property_id) { where(property_id: property_id) }
  scope :today, -> { where('created_at >= ?', Time.current.beginning_of_day) }
  scope :this_week, -> { where('created_at >= ?', Time.current.beginning_of_week) }
  scope :this_month, -> { where('created_at >= ?', Time.current.beginning_of_month) }
  scope :unique_users, -> { select(:user_id).distinct.where.not(user_id: nil) }
  
  # ============================================
  # SERIALIZATION
  # ============================================
  
  serialize :user_agent, coder: JSON
  serialize :referrer_data, coder: JSON
  
  # ============================================
  # CLASS METHODS
  # ============================================
  
  # Track a view
  def self.track(property:, user: nil, ip_address: nil, user_agent: nil, referrer: nil)
    create(
      property: property,
      user: user,
      ip_address: ip_address,
      user_agent: user_agent,
      referrer: referrer
    )
  end
  
  # Get views count by date range
  def self.count_by_date_range(start_date, end_date)
    where(created_at: start_date..end_date).count
  end
  
  # Get unique users count
  def self.unique_users_count
    unique_users.count
  end
  
  # ============================================
  # INSTANCE METHODS
  # ============================================
  
  # Device type detection
  def device_type
    return 'unknown' unless user_agent.present?
    
    ua = user_agent.to_s.downcase
    
    if ua.include?('mobile') || ua.include?('android') || ua.include?('iphone')
      'mobile'
    elsif ua.include?('tablet') || ua.include?('ipad')
      'tablet'
    else
      'desktop'
    end
  end
  
  # Browser detection (basic)
  def browser
    return 'unknown' unless user_agent.present?
    
    ua = user_agent.to_s.downcase
    
    return 'chrome' if ua.include?('chrome')
    return 'firefox' if ua.include?('firefox')
    return 'safari' if ua.include?('safari')
    return 'edge' if ua.include?('edge')
    return 'ie' if ua.include?('msie') || ua.include?('trident')
    
    'other'
  end
end

