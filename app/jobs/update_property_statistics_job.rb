# frozen_string_literal: true

# Update Property Statistics Job
# Updates various property statistics and counters
class UpdatePropertyStatisticsJob < ApplicationJob
  queue_as :low_priority
  
  # This job should be scheduled to run daily
  def perform
    Rails.logger.info 'Starting property statistics update'
    
    update_views_count
    update_inquiries_count
    update_favorites_count
    cleanup_old_views
    
    Rails.logger.info 'Property statistics update completed'
  end
  
  private
  
  def update_views_count
    # Update views_count for properties based on PropertyView records
    Property.find_each do |property|
      count = PropertyView.where(property_id: property.id).distinct.count(:user_id)
      property.update_column(:views_count, count) if property.views_count != count
    end
    
    Rails.logger.info 'Updated views count for all properties'
  end
  
  def update_inquiries_count
    # Update inquiries_count for properties
    Property.find_each do |property|
      count = Inquiry.where(property_id: property.id).count
      property.update_column(:inquiries_count, count) if property.inquiries_count != count
    end
    
    Rails.logger.info 'Updated inquiries count for all properties'
  end
  
  def update_favorites_count
    # Update favorites_count for properties
    Property.find_each do |property|
      count = Favorite.where(property_id: property.id).count
      property.update_column(:favorites_count, count) if property.favorites_count != count
    end
    
    Rails.logger.info 'Updated favorites count for all properties'
  end
  
  def cleanup_old_views
    # Remove property views older than 90 days for performance
    deleted_count = PropertyView.where('created_at < ?', 90.days.ago).delete_all
    Rails.logger.info "Cleaned up #{deleted_count} old property views"
  end
end

