# frozen_string_literal: true

module Api
  module V1
    class PropertiesController < BaseController
      # Skip authentication for public endpoints
      skip_before_action :authenticate_api_user!, only: [:index, :show, :search, :featured, :recent]
      
      before_action :set_property, only: [:show, :similar]
      
      # ============================================
      # PUBLIC ENDPOINTS
      # ============================================
      
      # GET /api/v1/properties
      # Returns paginated list of published properties
      def index
        @properties = Property.published
                              .includes(:property_type, :user)
        
        # Apply filters
        @properties = apply_property_filters(@properties)
        
        # Apply sorting
        @properties = apply_property_sorting(@properties)
        
        # Paginate
        @properties = paginate(@properties)
        
        render_success(
          properties: serialize_properties(@properties),
          meta: pagination_meta(@properties).merge(api_response_meta)
        )
      end
      
      # GET /api/v1/properties/:id
      # Returns detailed information about a property
      def show
        # Increment view counter
        @property.increment_views!
        
        # Track view if user is authenticated
        if current_api_user
          current_api_user.view_property(@property)
        end
        
        render_success(
          property: serialize_property_detail(@property),
          similar_properties: serialize_properties(@property.class.similar_to(@property, 4)),
          meta: api_response_meta
        )
      end
      
      # GET /api/v1/properties/search
      # Full-text search across properties
      def search
        query = params[:q]
        
        if query.blank?
          return render_error('Search query is required', status: :bad_request)
        end
        
        @properties = Property.published
                              .search_by_text(query)
                              .includes(:property_type, :user)
        
        # Apply additional filters
        @properties = apply_property_filters(@properties)
        
        # Paginate
        @properties = paginate(@properties)
        
        render_success(
          properties: serialize_properties(@properties),
          query: query,
          meta: pagination_meta(@properties).merge(api_response_meta)
        )
      end
      
      # GET /api/v1/properties/featured
      # Returns featured/premium properties
      def featured
        @properties = Property.published
                              .featured
                              .includes(:property_type, :user)
                              .limit(params[:limit] || 10)
        
        render_success(
          properties: serialize_properties(@properties),
          meta: { count: @properties.count }.merge(api_response_meta)
        )
      end
      
      # GET /api/v1/properties/recent
      # Returns recently added properties
      def recent
        days = params[:days].to_i
        days = 7 if days <= 0 || days > 90
        
        @properties = Property.published
                              .where('created_at >= ?', days.days.ago)
                              .includes(:property_type, :user)
                              .order(created_at: :desc)
                              .limit(params[:limit] || 20)
        
        render_success(
          properties: serialize_properties(@properties),
          meta: { 
            days: days,
            count: @properties.count 
          }.merge(api_response_meta)
        )
      end
      
      # GET /api/v1/properties/:id/similar
      # Returns similar properties
      def similar
        @similar = Property.similar_to(@property, params[:limit] || 4)
        
        render_success(
          properties: serialize_properties(@similar),
          meta: { count: @similar.count }.merge(api_response_meta)
        )
      end
      
      private
      
      # ============================================
      # CALLBACKS
      # ============================================
      
      def set_property
        @property = Property.friendly.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render_not_found('Property not found')
      end
      
      # ============================================
      # FILTERING
      # ============================================
      
      def apply_property_filters(scope)
        # Deal type filter
        if params[:deal_type].present?
          scope = scope.where(deal_type: params[:deal_type])
        end
        
        # Property type filter
        if params[:property_type_id].present?
          scope = scope.where(property_type_id: params[:property_type_id])
        end
        
        # Price range
        if params[:min_price].present?
          scope = scope.where('price >= ?', params[:min_price])
        end
        
        if params[:max_price].present?
          scope = scope.where('price <= ?', params[:max_price])
        end
        
        # Area range
        if params[:min_area].present?
          scope = scope.where('area >= ?', params[:min_area])
        end
        
        if params[:max_area].present?
          scope = scope.where('area <= ?', params[:max_area])
        end
        
        # Rooms
        if params[:rooms].present?
          scope = scope.where(rooms: params[:rooms])
        end
        
        # District
        if params[:district].present?
          scope = scope.where(district: params[:district])
        end
        
        # Metro station
        if params[:metro_station].present?
          scope = scope.where('metro_station ILIKE ?', "%#{params[:metro_station]}%")
        end
        
        # Features
        scope = scope.where(has_parking: true) if params[:has_parking] == 'true'
        scope = scope.where(has_balcony: true) if params[:has_balcony] == 'true'
        scope = scope.where(has_elevator: true) if params[:has_elevator] == 'true'
        scope = scope.where(pets_allowed: true) if params[:pets_allowed] == 'true'
        scope = scope.with_virtual_tour if params[:with_virtual_tour] == 'true'
        
        # Location radius (if lat, lng, radius provided)
        if params[:lat].present? && params[:lng].present? && params[:radius].present?
          scope = scope.within_radius(
            params[:lat].to_f,
            params[:lng].to_f,
            params[:radius].to_f
          )
        end
        
        scope
      end
      
      # ============================================
      # SORTING
      # ============================================
      
      def apply_property_sorting(scope)
        allowed_sorts = [:price, :area, :created_at, :views_count, :favorites_count]
        default_sort = :created_at
        
        sort_by = params[:sort_by]&.to_sym || default_sort
        sort_order = params[:sort_order]&.to_sym || :desc
        
        # Validate
        sort_by = default_sort unless allowed_sorts.include?(sort_by)
        sort_order = :desc unless [:asc, :desc].include?(sort_order)
        
        scope.order(sort_by => sort_order)
      end
      
      # ============================================
      # SERIALIZATION
      # ============================================
      
      def serialize_properties(properties)
        properties.map { |property| serialize_property(property) }
      end
      
      def serialize_property(property)
        {
          id: property.id,
          title: property.title,
          slug: property.slug,
          price: property.price,
          price_formatted: property.price_formatted,
          price_per_sqm: property.price_per_sqm,
          deal_type: property.deal_type,
          status: property.status,
          property_type: {
            id: property.property_type_id,
            name: property.property_type&.name
          },
          area: property.area,
          rooms: property.rooms,
          floor: property.floor,
          total_floors: property.total_floors,
          address: property.address,
          district: property.district,
          metro_station: property.metro_station,
          metro_distance: property.metro_distance,
          coordinates: {
            latitude: property.latitude,
            longitude: property.longitude
          },
          features: {
            has_parking: property.has_parking,
            has_balcony: property.has_balcony,
            has_elevator: property.has_elevator,
            has_security: property.has_security,
            pets_allowed: property.pets_allowed
          },
          stats: {
            views_count: property.views_count,
            favorites_count: property.favorites_count,
            inquiries_count: property.inquiries_count
          },
          has_virtual_tour: property.virtual_tour_url.present?,
          is_featured: property.is_featured,
          published_at: property.published_at,
          created_at: property.created_at,
          updated_at: property.updated_at,
          url: property_url(property, host: request.host_with_port, protocol: request.protocol)
        }
      end
      
      def serialize_property_detail(property)
        serialize_property(property).merge(
          description: property.description,
          living_area: property.living_area,
          kitchen_area: property.kitchen_area,
          bedrooms: property.bedrooms,
          bathrooms: property.bathrooms,
          building_year: property.building_year,
          building_type: property.building_type,
          condition: property.condition,
          ceiling_height: property.ceiling_height,
          window_view: property.window_view,
          furniture: property.furniture,
          appliances: property.appliances,
          ownership_type: property.ownership_type,
          owners_count: property.owners_count,
          mortgage_allowed: property.mortgage_allowed,
          video_url: property.video_url,
          virtual_tour_url: property.virtual_tour_url,
          images: property.image_urls,
          agent: property.user ? {
            id: property.user.id,
            name: property.user.full_name,
            phone: property.user.formatted_phone,
            email: property.user.email
          } : nil
        )
      end
    end
  end
end