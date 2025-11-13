# frozen_string_literal: true

class HomeController < ApplicationController
  # Homepage is public - no authentication required
  
  # Cache the entire page for better performance
  # caches_action :index, expires_in: 15.minutes, cache_path: proc { |c| c.params }
  
  def index
    # Track page view
    track_event('home_page_viewed')
    
    # Set meta tags for SEO
    set_page_meta_tags
    
    # Load data for homepage sections
    load_featured_properties
    load_latest_properties
    load_statistics
    load_reviews
    load_blog_posts
    load_virtual_tours
    
    # Prepare search form
    @search = Property.ransack(params[:q])
    
    # Track UTM parameters if present
    capture_utm_params if params[:utm_source].present?
    
    respond_to do |format|
      format.html
      format.json { render json: homepage_data }
    end
  end
  
  private
  
  # ============================================
  # META TAGS
  # ============================================
  def set_page_meta_tags
    set_meta_tags(
      title: 'АН "Виктори" - Покупка, продажа и аренда недвижимости',
      description: 'Агентство недвижимости АН "Виктори". Большой выбор квартир, домов и коммерческой недвижимости. Помощь с ипотекой, юридическое сопровождение сделок.',
      keywords: 'недвижимость, купить квартиру, снять квартиру, продать квартиру, ипотека, агентство недвижимости, Москва',
      og: {
        title: 'АН "Виктори" - Агентство недвижимости',
        description: 'Покупка, продажа и аренда недвижимости. Профессиональные услуги и поддержка на всех этапах сделки.',
        # image: view_context.asset_url('og-image.jpg'), # Временно отключено - asset не найден
        url: root_url
      },
      twitter: {
        card: 'summary_large_image',
        title: 'АН "Виктори" - Агентство недвижимости',
        description: 'Покупка, продажа и аренда недвижимости'
        # image: view_context.asset_url('twitter-card.jpg') # Временно отключено - asset не найден
      }
    )
  end
  
  # ============================================
  # DATA LOADING
  # ============================================
  
  # Featured properties (premium listings)
  def load_featured_properties
    @featured_properties = Rails.cache.fetch('homepage/featured_properties', expires_in: 30.minutes) do
      Property.published
              .featured
              .includes(:property_type, :property_images, :user)
              .limit(6)
              .to_a
    end
  end
  
  # Latest properties (most recent listings)
  def load_latest_properties
    @latest_properties = Rails.cache.fetch('homepage/latest_properties', expires_in: 15.minutes) do
      Property.published
              .recent
              .includes(:property_type, :property_images)
              .limit(12)
              .to_a
    end
  end
  
  # Statistics for the "stats in real-time" section
  def load_statistics
    @statistics = Rails.cache.fetch('homepage/statistics', expires_in: 1.hour) do
      {
        total_properties: Property.published.count,
        properties_for_sale: Property.published.for_sale.count,
        properties_for_rent: Property.published.for_rent.count,
        total_clients: User.clients.count,
        successful_deals: Property.where(status: [:sold, :rented]).count,
        avg_response_time: calculate_avg_response_time,
        this_week_new: Property.published.where('published_at >= ?', 1.week.ago).count,
        avg_price_sale: Property.published.for_sale.average(:price)&.to_i,
        avg_price_rent: Property.published.for_rent.average(:price)&.to_i
      }
    end
  end
  
  # Customer reviews
  def load_reviews
    @reviews = Rails.cache.fetch('homepage/reviews', expires_in: 1.hour) do
      Review.where(status: :approved, visible: true)
            .includes(:user)
            .order(created_at: :desc)
            .limit(10)
            .to_a
    rescue NameError
      # Review model might not exist yet
      []
    end
  end
  
  # Blog posts for the blog section
  def load_blog_posts
    @blog_posts = Rails.cache.fetch('homepage/blog_posts', expires_in: 1.hour) do
      # Placeholder - replace with actual blog model when implemented
      # BlogPost.published.order(created_at: :desc).limit(3)
      []
    end
  end
  
  # Virtual tours showcase
  def load_virtual_tours
    @virtual_tours = Rails.cache.fetch('homepage/virtual_tours', expires_in: 1.hour) do
      Property.published
              .with_virtual_tour
              .includes(:property_type)
              .order('RANDOM()')
              .limit(4)
              .to_a
    end
  end
  
  # ============================================
  # HELPERS
  # ============================================
  
  # Calculate average response time for inquiries
  def calculate_avg_response_time
    return 0 unless defined?(Inquiry)
    
    Inquiry.where.not(processed_at: nil)
           .where('created_at >= ?', 1.month.ago)
           .pluck(:created_at, :processed_at)
           .map { |created, processed| (processed - created) / 3600.0 }
           .then { |times| times.empty? ? 0 : (times.sum / times.size).round(1) }
  rescue
    0
  end
  
  # Prepare all data for JSON response
  def homepage_data
    {
      featured_properties: @featured_properties.map { |p| property_summary(p) },
      latest_properties: @latest_properties.map { |p| property_summary(p) },
      statistics: @statistics,
      reviews: @reviews.map { |r| review_summary(r) },
      blog_posts: @blog_posts,
      virtual_tours: @virtual_tours.map { |p| property_summary(p) }
    }
  end
  
  # Compact property data for JSON
  def property_summary(property)
    {
      id: property.id,
      title: property.title,
      price: property.price,
      price_formatted: property.price_formatted,
      area: property.area,
      rooms: property.rooms,
      address: property.address,
      url: property_url(property),
      image_url: property.primary_image&.url || view_context.asset_url('placeholder-property.jpg'),
      deal_type: property.deal_type,
      is_featured: property.is_featured
    }
  end
  
  # Compact review data for JSON
  def review_summary(review)
    {
      id: review.id,
      author: review.user.full_name,
      rating: review.rating,
      body: review.body,
      created_at: review.created_at
    }
  rescue
    nil
  end
end