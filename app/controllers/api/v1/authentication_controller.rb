# frozen_string_literal: true

module Api
  module V1
    class AuthenticationController < BaseController
      # Skip authentication for login, logout (logout optional), and refresh
      skip_before_action :authenticate_api_user!, only: [:login, :register]
      
      # ============================================
      # LOGIN
      # ============================================
      
      # POST /api/v1/auth/login
      # Authenticates user and returns JWT token
      def login
        @user = User.find_by(email: params[:email]&.downcase)
        
        if @user.nil?
          return render_unauthorized('Invalid email or password')
        end
        
        unless @user.valid_password?(params[:password])
          return render_unauthorized('Invalid email or password')
        end
        
        unless @user.active?
          return render_unauthorized('Account is inactive')
        end
        
        # Check if account is locked
        if @user.access_locked?
          return render_unauthorized('Account is locked. Please check your email for unlock instructions.')
        end
        
        # Generate JWT token
        token = generate_token(@user)
        refresh_token = generate_refresh_token(@user)
        
        # Update last sign in
        @user.update_columns(
          last_sign_in_at: Time.current,
          last_sign_in_ip: request.remote_ip,
          sign_in_count: @user.sign_in_count + 1,
          current_sign_in_at: Time.current,
          current_sign_in_ip: request.remote_ip
        )
        
        # Track login event
        track_api_event('api_login_success', user_id: @user.id)
        
        render_success(
          message: 'Login successful',
          data: {
            token: token,
            refresh_token: refresh_token,
            expires_in: token_expiration_hours.hours.to_i,
            user: serialize_user(@user)
          }
        )
      end
      
      # ============================================
      # LOGOUT
      # ============================================
      
      # POST /api/v1/auth/logout
      # Logs out the current user (JWT is stateless, so just returns success)
      def logout
        # Since JWT is stateless, we can't invalidate tokens
        # In production, consider using a token blacklist in Redis
        
        track_api_event('api_logout', user_id: current_api_user&.id)
        
        render_success(
          message: 'Logout successful',
          data: {}
        )
      end
      
      # ============================================
      # REFRESH TOKEN
      # ============================================
      
      # POST /api/v1/auth/refresh
      # Refreshes the JWT token
      def refresh
        refresh_token = params[:refresh_token]
        
        if refresh_token.blank?
          return render_unauthorized('Refresh token is required')
        end
        
        begin
          decoded = decode_refresh_token(refresh_token)
          @user = User.find(decoded['user_id'])
          
          unless @user.active?
            return render_unauthorized('Account is inactive')
          end
          
          # Generate new tokens
          new_token = generate_token(@user)
          new_refresh_token = generate_refresh_token(@user)
          
          track_api_event('api_token_refreshed', user_id: @user.id)
          
          render_success(
            message: 'Token refreshed successfully',
            data: {
              token: new_token,
              refresh_token: new_refresh_token,
              expires_in: token_expiration_hours.hours.to_i,
              user: serialize_user(@user)
            }
          )
        rescue JWT::DecodeError, JWT::ExpiredSignature
          render_unauthorized('Invalid or expired refresh token')
        rescue ActiveRecord::RecordNotFound
          render_unauthorized('User not found')
        end
      end
      
      # ============================================
      # REGISTER (Optional)
      # ============================================
      
      # POST /api/v1/auth/register
      # Registers a new user
      def register
        @user = User.new(registration_params)
        @user.role = :client
        
        if @user.save
          # Generate tokens
          token = generate_token(@user)
          refresh_token = generate_refresh_token(@user)
          
          # Send confirmation email (if confirmable is enabled)
          # @user.send_confirmation_instructions if @user.respond_to?(:send_confirmation_instructions)
          
          track_api_event('api_registration_success', user_id: @user.id)
          
          render_created(
            {
              token: token,
              refresh_token: refresh_token,
              expires_in: token_expiration_hours.hours.to_i,
              user: serialize_user(@user)
            },
            message: 'Registration successful. Please check your email for confirmation.'
          )
        else
          render_error(
            'Registration failed',
            errors: @user.errors.full_messages,
            status: :unprocessable_entity
          )
        end
      end
      
      # ============================================
      # CURRENT USER INFO
      # ============================================
      
      # GET /api/v1/auth/me
      # Returns current authenticated user information
      def me
        render_success(
          user: serialize_user(current_api_user),
          meta: api_response_meta
        )
      end
      
      private
      
      # ============================================
      # TOKEN GENERATION
      # ============================================
      
      def generate_token(user)
        payload = {
          user_id: user.id,
          email: user.email,
          role: user.role,
          exp: token_expiration_hours.hours.from_now.to_i,
          iat: Time.current.to_i,
          type: 'access'
        }
        
        encode_jwt_token(payload)
      end
      
      def generate_refresh_token(user)
        payload = {
          user_id: user.id,
          exp: refresh_token_expiration_days.days.from_now.to_i,
          iat: Time.current.to_i,
          type: 'refresh'
        }
        
        JWT.encode(
          payload,
          jwt_secret_key,
          'HS256'
        )
      end
      
      def decode_refresh_token(token)
        JWT.decode(
          token,
          jwt_secret_key,
          true,
          { algorithm: 'HS256', verify_expiration: true }
        ).first
      end
      
      def token_expiration_hours
        ENV.fetch('JWT_EXPIRATION_HOURS', 24).to_i
      end
      
      def refresh_token_expiration_days
        ENV.fetch('JWT_REFRESH_EXPIRATION_DAYS', 30).to_i
      end
      
      # ============================================
      # STRONG PARAMETERS
      # ============================================
      
      def registration_params
        params.require(:user).permit(
          :email,
          :password,
          :password_confirmation,
          :first_name,
          :last_name,
          :phone
        )
      end
      
      # ============================================
      # SERIALIZATION
      # ============================================
      
      def serialize_user(user)
        {
          id: user.id,
          email: user.email,
          first_name: user.first_name,
          last_name: user.last_name,
          full_name: user.full_name,
          phone: user.phone,
          phone_formatted: user.formatted_phone,
          role: user.role,
          avatar_url: user.avatar_path,
          confirmed: user.confirmed?,
          active: user.active?,
          created_at: user.created_at,
          stats: {
            properties_count: user.properties_count,
            favorites_count: user.favorites_count,
            inquiries_count: user.inquiries_count
          }
        }
      end
      
      # ============================================
      # ANALYTICS
      # ============================================
      
      def track_api_event(event_name, data = {})
        Rails.logger.info({
          event: event_name,
          api_version: 'v1',
          timestamp: Time.current.iso8601,
          ip: request.remote_ip,
          user_agent: request.user_agent,
          **data
        }.to_json)
        
        # Track with Ahoy if available
        if defined?(Ahoy)
          ahoy.track(event_name, data.merge(
            api: true,
            version: 'v1'
          ))
        end
      end
    end
  end
end