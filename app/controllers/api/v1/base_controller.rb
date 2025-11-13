# frozen_string_literal: true

module Api
  module V1
    class BaseController < ActionController::API
      # ============================================
      # INCLUDES
      # ============================================
      include ActionController::HttpAuthentication::Token::ControllerMethods
      include Pundit::Authorization
      
      # ============================================
      # BEFORE ACTIONS
      # ============================================
      before_action :authenticate_api_user!
      before_action :set_default_format
      
      # ============================================
      # RESCUE FROM
      # ============================================
      rescue_from ActiveRecord::RecordNotFound, with: :record_not_found
      rescue_from ActiveRecord::RecordInvalid, with: :record_invalid
      rescue_from Pundit::NotAuthorizedError, with: :user_not_authorized
      rescue_from ActionController::ParameterMissing, with: :parameter_missing
      rescue_from ArgumentError, with: :bad_request
      
      # ============================================
      # AUTHENTICATION
      # ============================================
      
      def authenticate_api_user!
        token = extract_token_from_header
        
        if token.blank?
          render_unauthorized('Missing authentication token')
          return
        end
        
        begin
          decoded = decode_jwt_token(token)
          @current_api_user = User.find(decoded['user_id'])
          
          unless @current_api_user.active?
            render_unauthorized('User account is inactive')
          end
        rescue JWT::DecodeError => e
          render_unauthorized('Invalid token')
        rescue JWT::ExpiredSignature
          render_unauthorized('Token has expired')
        rescue ActiveRecord::RecordNotFound
          render_unauthorized('User not found')
        end
      end
      
      def current_api_user
        @current_api_user
      end
      
      def extract_token_from_header
        auth_header = request.headers['Authorization']
        return nil unless auth_header
        
        auth_header.split(' ').last if auth_header.start_with?('Bearer ')
      end
      
      def decode_jwt_token(token)
        JWT.decode(
          token,
          jwt_secret_key,
          true,
          { algorithm: 'HS256' }
        ).first
      end
      
      def encode_jwt_token(payload)
        expiration = ENV.fetch('JWT_EXPIRATION_HOURS', 24).to_i.hours.from_now.to_i
        
        payload[:exp] = expiration
        
        JWT.encode(
          payload,
          jwt_secret_key,
          'HS256'
        )
      end
      
      def jwt_secret_key
        ENV.fetch('JWT_SECRET_KEY', Rails.application.credentials.secret_key_base)
      end
      
      # ============================================
      # AUTHORIZATION HELPERS
      # ============================================
      
      def current_user_admin?
        current_api_user&.admin?
      end
      
      def current_user_agent?
        current_api_user&.agent?
      end
      
      def current_user_client?
        current_api_user&.client?
      end
      
      def require_admin!
        unless current_user_admin?
          render_forbidden('Admin access required')
        end
      end
      
      def require_agent!
        unless current_user_agent? || current_user_admin?
          render_forbidden('Agent access required')
        end
      end
      
      # ============================================
      # RESPONSE HELPERS
      # ============================================
      
      def render_success(data = {}, message: nil, status: :ok, meta: {})
        response_data = {
          success: true,
          data: data
        }
        
        response_data[:message] = message if message.present?
        response_data[:meta] = meta if meta.present?
        
        render json: response_data, status: status
      end
      
      def render_error(message, errors: [], status: :unprocessable_entity)
        render json: {
          success: false,
          error: message,
          errors: errors
        }, status: status
      end
      
      def render_created(resource, message: 'Resource created successfully')
        render json: {
          success: true,
          message: message,
          data: resource
        }, status: :created
      end
      
      def render_updated(resource, message: 'Resource updated successfully')
        render json: {
          success: true,
          message: message,
          data: resource
        }, status: :ok
      end
      
      def render_deleted(message: 'Resource deleted successfully')
        render json: {
          success: true,
          message: message
        }, status: :ok
      end
      
      def render_unauthorized(message = 'Unauthorized')
        render json: {
          success: false,
          error: message
        }, status: :unauthorized
      end
      
      def render_forbidden(message = 'Forbidden')
        render json: {
          success: false,
          error: message
        }, status: :forbidden
      end
      
      def render_not_found(message = 'Resource not found')
        render json: {
          success: false,
          error: message
        }, status: :not_found
      end
      
      def render_bad_request(message = 'Bad request')
        render json: {
          success: false,
          error: message
        }, status: :bad_request
      end
      
      # ============================================
      # PAGINATION
      # ============================================
      
      def paginate(collection)
        page = params[:page].to_i
        page = 1 if page < 1
        
        per_page = params[:per_page].to_i
        per_page = default_per_page if per_page < 1
        per_page = max_per_page if per_page > max_per_page
        
        collection.page(page).per(per_page)
      end
      
      def pagination_meta(collection)
        {
          current_page: collection.current_page,
          next_page: collection.next_page,
          prev_page: collection.prev_page,
          total_pages: collection.total_pages,
          total_count: collection.total_count,
          per_page: collection.limit_value
        }
      end
      
      def default_per_page
        ENV.fetch('API_DEFAULT_PER_PAGE', 20).to_i
      end
      
      def max_per_page
        ENV.fetch('API_MAX_PER_PAGE', 100).to_i
      end
      
      # ============================================
      # ERROR HANDLERS
      # ============================================
      
      def record_not_found(exception)
        render_not_found(exception.message)
      end
      
      def record_invalid(exception)
        render_error(
          'Validation failed',
          errors: exception.record.errors.full_messages,
          status: :unprocessable_entity
        )
      end
      
      def user_not_authorized(exception)
        render_forbidden('You are not authorized to perform this action')
      end
      
      def parameter_missing(exception)
        render_bad_request("Missing parameter: #{exception.param}")
      end
      
      def bad_request(exception)
        render_bad_request(exception.message)
      end
      
      # ============================================
      # FORMAT HELPERS
      # ============================================
      
      def set_default_format
        request.format = :json unless params[:format]
      end
      
      # ============================================
      # RATE LIMITING INFO
      # ============================================
      
      def rate_limit_headers
        {
          'X-RateLimit-Limit' => ENV.fetch('API_RATE_LIMIT', 100).to_s,
          'X-RateLimit-Remaining' => calculate_remaining_requests.to_s,
          'X-RateLimit-Reset' => rate_limit_reset_time.to_s
        }
      end
      
      def calculate_remaining_requests
        # Implement with Redis or Rack::Attack
        100 # Placeholder
      end
      
      def rate_limit_reset_time
        1.hour.from_now.to_i
      end
      
      # ============================================
      # FILTERING & SORTING
      # ============================================
      
      def apply_filters(collection, allowed_filters)
        allowed_filters.each do |filter|
          if params[filter].present?
            collection = collection.where(filter => params[filter])
          end
        end
        
        collection
      end
      
      def apply_sorting(collection, allowed_sorts, default_sort = :created_at)
        sort_by = params[:sort_by]&.to_sym
        sort_order = params[:sort_order]&.to_sym
        
        sort_by = default_sort unless allowed_sorts.include?(sort_by)
        sort_order = :desc unless [:asc, :desc].include?(sort_order)
        
        collection.order(sort_by => sort_order)
      end
      
      # ============================================
      # API VERSIONING
      # ============================================
      
      def api_version
        'v1'
      end
      
      def api_response_meta
        {
          version: api_version,
          timestamp: Time.current.iso8601,
          endpoint: request.path
        }
      end
      
      # ============================================
      # LOGGING
      # ============================================
      
      def log_api_request
        Rails.logger.info({
          api_version: api_version,
          endpoint: request.path,
          method: request.method,
          user_id: current_api_user&.id,
          ip: request.remote_ip,
          user_agent: request.user_agent,
          params: filtered_params
        }.to_json)
      end
      
      def filtered_params
        params.except(:controller, :action, :format).to_unsafe_h
      end
    end
  end
end