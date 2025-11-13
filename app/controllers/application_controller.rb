# frozen_string_literal: true

class ApplicationController < ActionController::Base
  # ============================================
  # SECURITY
  # ============================================
  # Prevent CSRF attacks by raising an exception.
  # For APIs, you may want to use :null_session instead.
  protect_from_forgery with: :exception
  
  # ============================================
  # INCLUDES
  # ============================================
  include Pundit::Authorization
  
  # ============================================
  # BEFORE ACTIONS
  # ============================================
  before_action :configure_permitted_parameters, if: :devise_controller?
  before_action :set_locale
  before_action :track_user_activity
  before_action :setup_meta_tags
  # Временно отключено: требуется gem browser
  # before_action :detect_device_type
  
  # ============================================
  # AFTER ACTIONS
  # ============================================
  after_action :track_ahoy_visit
  
  # ============================================
  # RESCUE FROM
  # ============================================
  rescue_from Pundit::NotAuthorizedError, with: :user_not_authorized
  rescue_from ActiveRecord::RecordNotFound, with: :record_not_found
  rescue_from ActionController::RoutingError, with: :render_404
  
  # ============================================
  # HELPER METHODS
  # ============================================
  helper_method :current_user_admin?
  helper_method :current_user_agent?
  helper_method :current_user_client?
  helper_method :mobile_device?
  helper_method :tablet_device?
  helper_method :desktop_device?
  
  protected
  
  # ============================================
  # DEVISE CONFIGURATION
  # ============================================
  def configure_permitted_parameters
    devise_parameter_sanitizer.permit(:sign_up, keys: [
      :first_name, 
      :last_name, 
      :phone, 
      :avatar
    ])
    
    devise_parameter_sanitizer.permit(:account_update, keys: [
      :first_name, 
      :last_name, 
      :phone, 
      :avatar,
      :bio,
      :company,
      :position
    ])
  end
  
  # ============================================
  # LOCALE
  # ============================================
  def set_locale
    I18n.locale = extract_locale || I18n.default_locale
  end
  
  def extract_locale
    parsed_locale = params[:locale] || session[:locale] || extract_locale_from_accept_language_header
    I18n.available_locales.map(&:to_s).include?(parsed_locale) ? parsed_locale : nil
  end
  
  def extract_locale_from_accept_language_header
    return unless request.env['HTTP_ACCEPT_LANGUAGE']
    
    request.env['HTTP_ACCEPT_LANGUAGE'].scan(/^[a-z]{2}/).first
  end
  
  # ============================================
  # USER ACTIVITY TRACKING
  # ============================================
  def track_user_activity
    return unless current_user
    
    current_user.touch_activity! if current_user.respond_to?(:touch_activity!)
  end
  
  # ============================================
  # META TAGS
  # ============================================
  def setup_meta_tags
    set_meta_tags site: 'АН "Виктори"',
                  reverse: true,
                  separator: '—',
                  description: 'Агентство недвижимости АН "Виктори" - покупка, продажа и аренда недвижимости',
                  keywords: 'недвижимость, квартиры, продажа, аренда, Москва',
                  og: {
                    site_name: 'АН "Виктори"',
                    type: 'website',
                    locale: 'ru_RU'
                  },
                  twitter: {
                    card: 'summary_large_image'
                  }
  end
  
  # ============================================
  # DEVICE DETECTION
  # ============================================
  def detect_device_type
    @device_type = if browser.device.mobile?
                     :mobile
                   elsif browser.device.tablet?
                     :tablet
                   else
                     :desktop
                   end
  end
  
  def mobile_device?
    @device_type == :mobile
  end
  
  def tablet_device?
    @device_type == :tablet
  end
  
  def desktop_device?
    @device_type == :desktop
  end
  
  # ============================================
  # BROWSER DETECTION
  # ============================================
  def browser
    @browser ||= Browser.new(request.user_agent)
  end
  
  # ============================================
  # USER ROLE CHECKS
  # ============================================
  def current_user_admin?
    current_user&.admin?
  end
  
  def current_user_agent?
    current_user&.agent?
  end
  
  def current_user_client?
    current_user&.client?
  end
  
  # ============================================
  # AUTHORIZATION HELPERS
  # ============================================
  def require_admin!
    unless current_user_admin?
      flash[:alert] = 'У вас нет прав для выполнения этого действия'
      redirect_to root_path
    end
  end
  
  def require_agent!
    unless current_user_agent? || current_user_admin?
      flash[:alert] = 'У вас нет прав для выполнения этого действия'
      redirect_to root_path
    end
  end
  
  # ============================================
  # ANALYTICS
  # ============================================
  def track_ahoy_visit
    # Ahoy gem automatically tracks visits
    # Additional custom tracking can be added here
  end
  
  def track_event(name, properties = {})
    return unless defined?(Ahoy)
    
    ahoy.track(name, properties.merge(
      user_id: current_user&.id,
      device_type: @device_type,
      user_agent: request.user_agent,
      ip: request.remote_ip
    ))
  end
  
  # ============================================
  # PAGINATION
  # ============================================
  def per_page
    per = params[:per_page].to_i
    per = ENV.fetch('DEFAULT_PER_PAGE', 20).to_i if per <= 0
    per = ENV.fetch('MAX_PER_PAGE', 100).to_i if per > ENV.fetch('MAX_PER_PAGE', 100).to_i
    per
  end
  
  # ============================================
  # REDIRECT HELPERS
  # ============================================
  def redirect_back_or_to(default_path, **options)
    redirect_to(request.referer || default_path, **options)
  end
  
  def store_location
    session[:return_to] = request.fullpath if request.get?
  end
  
  def redirect_to_stored_location(default_path)
    redirect_to(session.delete(:return_to) || default_path)
  end
  
  # ============================================
  # ERROR HANDLING
  # ============================================
  def user_not_authorized(exception)
    policy_name = exception.policy.class.to_s.underscore
    
    flash[:alert] = t("pundit.#{policy_name}.#{exception.query}", 
                      default: 'У вас нет прав для выполнения этого действия')
    
    if current_user
      redirect_to(request.referer || root_path)
    else
      redirect_to new_user_session_path
    end
  end
  
  def record_not_found
    flash[:alert] = 'Запрашиваемая запись не найдена'
    redirect_to root_path
  end
  
  def render_404
    respond_to do |format|
      format.html { render file: Rails.public_path.join('404.html'), status: :not_found, layout: false }
      format.json { render json: { error: 'Not found' }, status: :not_found }
      format.any  { head :not_found }
    end
  end
  
  def render_500
    respond_to do |format|
      format.html { render file: Rails.public_path.join('500.html'), status: :internal_server_error, layout: false }
      format.json { render json: { error: 'Internal server error' }, status: :internal_server_error }
      format.any  { head :internal_server_error }
    end
  end
  
  # ============================================
  # RESPONSE HELPERS
  # ============================================
  def render_success(message = 'Операция выполнена успешно', status: :ok)
    respond_to do |format|
      format.html { 
        flash[:notice] = message
        redirect_back_or_to root_path
      }
      format.json { render json: { success: true, message: message }, status: status }
    end
  end
  
  def render_error(message = 'Произошла ошибка', status: :unprocessable_entity)
    respond_to do |format|
      format.html { 
        flash[:alert] = message
        redirect_back_or_to root_path
      }
      format.json { render json: { success: false, error: message }, status: status }
    end
  end
  
  # ============================================
  # REQUEST HELPERS
  # ============================================
  def xhr_request?
    request.xhr? || request.format.json?
  end
  
  def turbo_frame_request?
    request.headers['Turbo-Frame'].present?
  end
  
  # ============================================
  # UTM TRACKING
  # ============================================
  def capture_utm_params
    return unless params[:utm_source].present?
    
    session[:utm_params] = {
      utm_source: params[:utm_source],
      utm_medium: params[:utm_medium],
      utm_campaign: params[:utm_campaign],
      utm_term: params[:utm_term],
      utm_content: params[:utm_content]
    }.compact
  end
  
  def utm_params
    session[:utm_params] || {}
  end
  
  # ============================================
  # BREADCRUMBS
  # ============================================
  def add_breadcrumb(name, path = nil)
    @breadcrumbs ||= []
    @breadcrumbs << { name: name, path: path }
  end
  
  # ============================================
  # API HELPERS
  # ============================================
  def current_api_user
    return @current_api_user if defined?(@current_api_user)
    
    if request.headers['Authorization'].present?
      token = request.headers['Authorization'].split(' ').last
      @current_api_user = decode_jwt_token(token)
    end
  rescue
    @current_api_user = nil
  end
  
  def decode_jwt_token(token)
    return unless token
    
    decoded = JWT.decode(
      token,
      ENV['JWT_SECRET_KEY'] || Rails.application.credentials.secret_key_base,
      true,
      algorithm: 'HS256'
    )
    
    User.find_by(id: decoded[0]['user_id'])
  rescue JWT::DecodeError, JWT::ExpiredSignature
    nil
  end
  
  # ============================================
  # FEATURE FLAGS
  # ============================================
  def feature_enabled?(feature_name)
    return true unless defined?(Flipper)
    
    Flipper.enabled?(feature_name, current_user)
  end
  
  helper_method :feature_enabled?
  
  # ============================================
  # NOTIFICATIONS
  # ============================================
  def notify_user(message, type: :info)
    flash[type] = message
  end
  
  def notify_success(message)
    notify_user(message, type: :notice)
  end
  
  def notify_error(message)
    notify_user(message, type: :alert)
  end
  
  def notify_warning(message)
    notify_user(message, type: :warning)
  end
  
  # ============================================
  # PRIVATE METHODS
  # ============================================
  private
  
  # Override Devise's after_sign_in_path
  def after_sign_in_path_for(resource)
    stored_location_for(resource) || dashboard_root_path || root_path
  end
  
  # Override Devise's after_sign_out_path
  def after_sign_out_path_for(resource_or_scope)
    root_path
  end
end