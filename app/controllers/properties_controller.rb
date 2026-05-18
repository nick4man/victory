# frozen_string_literal: true

class PropertiesController < ApplicationController
  # Public pages - no authentication required
  # Private actions require authentication via before_action below
  
  before_action :set_property, only: [:show, :edit, :update, :destroy, :favorite, :unfavorite,
                                       :schedule_viewing, :share, :print, :report, :dossier]
  before_action :authorize_property, only: [:edit, :update, :destroy]
  
  # Require authentication for these actions
  before_action :authenticate_user!, only: [:new, :create, :edit, :update, :destroy,
                                             :favorite, :unfavorite, :schedule_viewing]
  
  # Pagination
  before_action :set_per_page, only: [:index, :search]
  
  # ============================================
  # PUBLIC ACTIONS
  # ============================================
  
  # GET /properties
  def index
    # Build ransack search
    @q = Property.on_site.ransack(params[:q])

    # Apply filters
    @properties = @q.result(distinct: true)
                    .includes(:property_type, :user)
                    .order(sort_order)

    # Premium-сегмент фильтр (Phase A). Convention-простой `?premium=1` —
    # независим от ransack `q[...]` params чтобы work с `link_to '/properties?premium=1'`.
    # Logic пересекается с scope Property.premium.
    if ActiveModel::Type::Boolean.new.cast(params[:premium])
      @properties = @properties.premium
      @premium_filter_active = true
    end
    
    # Store search in session for "back to results" functionality
    session[:property_search] = request.fullpath
    
    # Pagination
    @properties = @properties.page(params[:page]).per(@per_page)
    
    # Get AI recommendations if user is logged in
    if current_user
      @recommended_properties = Property.recommended_for_user(current_user, 6)
    end
    
    # Statistics — recount on the same scope that pagination renders so
    # the «Found N» pill stays consistent when premium filter is on.
    stats_scope = @premium_filter_active ? @q.result.premium : @q.result
    @total_count = stats_scope.count
    @avg_price = stats_scope.average(:price)
    
    # Track search event
    track_event('properties_searched', {
      filters: params[:q],
      results_count: @total_count
    })
    
    respond_to do |format|
      format.html
      format.json { render json: properties_json }
      format.xml  { render xml: @properties }
    end
  end
  
  # GET /properties/:id
  def show
    # Conditional GET — 304 when the bot/browser already has a copy whose
    # ETag matches @property's cache_key_with_version. Big crawl-rate win
    # for Yandex (304 responses cost ~5ms vs 800ms+ full render), and the
    # early return also prevents bot revisits from inflating view counters
    # below since side effects only run on stale (200) responses.
    return if stale?(@property, public: true)

    # Increment view counter
    @property.increment_views!
    
    # Track view for current user
    if current_user
      current_user.view_property(@property)
    else
      # Track anonymous view
      PropertyView.create(
        property: @property,
        ip_address: request.remote_ip,
        user_agent: request.user_agent,
        referrer_url: request.referer,
        session_id: session.id
      )
    end
    
    # Load related data
    @similar_properties = Property.similar_to(@property, 4)

    # "More in this district" — separate internal-linking block. similar_to
    # filters by price+area+deal_type which often crosses districts; this
    # block keeps users (and crawlers) inside the same geo cluster, giving
    # Yandex a stronger neighborhood-relevance signal.
    @district_properties = if @property.district.present?
                             Property.on_site
                                     .in_district(@property.district)
                                     .where.not(id: @property.id)
                                     .order(Arel.sql('RANDOM()'))
                                     .limit(4)
                           else
                             Property.none
                           end
    # @property_images = @property.property_images.order(:position)
    # PropertyImage model is not implemented yet — Active Storage `images` are
    # used directly in the view (see properties/show.html.erb).
    @property_images = []
    
    # Price history — order by effective_date (PriceHistory schema uses
    # effective_date not "changed_at"; latent bug pre-existing since at
    # the time of writing 0 rows existed, so the typo never surfaced).
    @price_history = @property.price_histories.order(effective_date: :desc).limit(10)
    
    # Reviews — Property has no has_many :reviews association at the moment.
    @reviews = @property.respond_to?(:reviews) ? @property.reviews.approved.order(created_at: :desc).limit(5) : []
    
    # Check if favorited
    @is_favorited = current_user&.favorited?(@property)
    
    # Breadcrumbs
    add_breadcrumb 'Каталог', properties_path
    add_breadcrumb @property.title
    
    # SEO meta tags
    set_property_meta_tags
    
    # Track analytics
    track_event('property_viewed', {
      property_id: @property.id,
      property_type: @property.property_type&.name,
      price: @property.price,
      area: @property.area
    })
    
    respond_to do |format|
      format.html
      format.json { render json: property_detail_json }
    end
  end
  
  # GET /properties/new
  def new
    @property = current_user.properties.build
    @property_types = PropertyType.active.order(:position)
    
    add_breadcrumb 'Каталог', properties_path
    add_breadcrumb 'Новое объявление'
  end
  
  # POST /properties
  def create
    @property = current_user.properties.build(property_params)
    @property.status = :pending # Set to pending moderation
    
    if @property.save
      track_event('property_created', { property_id: @property.id })
      
      redirect_to @property, notice: 'Объект недвижимости успешно добавлен и отправлен на модерацию'
    else
      @property_types = PropertyType.active.order(:position)
      render :new, status: :unprocessable_entity
    end
  end
  
  # GET /properties/:id/edit
  def edit
    @property_types = PropertyType.active.order(:position)
    
    add_breadcrumb 'Каталог', properties_path
    add_breadcrumb @property.title, property_path(@property)
    add_breadcrumb 'Редактирование'
  end
  
  # PATCH/PUT /properties/:id
  def update
    old_price = @property.price
    
    if @property.update(property_params)
      # Track price change
      if @property.price != old_price
        track_event('property_price_changed', {
          property_id: @property.id,
          old_price: old_price,
          new_price: @property.price
        })
      end
      
      redirect_to @property, notice: 'Объект недвижимости успешно обновлен'
    else
      @property_types = PropertyType.active.order(:position)
      render :edit, status: :unprocessable_entity
    end
  end
  
  # DELETE /properties/:id
  def destroy
    @property.soft_delete!
    
    track_event('property_deleted', { property_id: @property.id })
    
    redirect_to properties_path, notice: 'Объект недвижимости успешно удален'
  end
  
  # ============================================
  # COLLECTION ACTIONS
  # ============================================
  
  # GET /properties/map
  def map
    @q = Property.on_site.ransack(params[:q])
    @properties = @q.result(distinct: true)
                    .where.not(latitude: nil, longitude: nil)
                    .includes(:property_type)
                    .limit(500) # Limit for performance
    
    @map_center = calculate_map_center
    @map_zoom = params[:zoom] || 12
    
    track_event('properties_map_viewed')
    
    respond_to do |format|
      format.html
      format.json { render json: map_properties_json }
    end
  end
  
  # GET /properties/search
  def search
    # The search action and the catalog (index) share the index template
    # but use params[:q] differently: search treats it as a free-text
    # string, index treats it as a Ransack hash. Stash the query under a
    # different name so the template's `params.dig(:q, :deal_type_eq)`
    # doesn't crash on a String.
    @search_query = params[:q].to_s
    params[:q] = nil
    @q = Property.on_site.ransack({}) # empty ransack so search_form_for renders

    # Search-result URLs are an infinite-permutation space and dilute crawl
    # budget if indexed. noindex (follow keeps internal links live) tells
    # both Yandex and Google to crawl-but-not-index these.
    response.headers['X-Robots-Tag'] = 'noindex, follow'

    @properties = Property.published
                          .search_by_text(@search_query)
                          .includes(:property_type)
                          .page(params[:page])
                          .per(@per_page)

    @total_count = @properties.respond_to?(:total_count) ? @properties.total_count : @properties.size

    track_event('property_text_search', { query: @search_query })

    respond_to do |format|
      format.html { render :index }
      format.json { render json: properties_json }
    end
  end
  
  # GET /properties/autocomplete
  def autocomplete
    query = params[:q]
    
    results = Property.published
                      .search_by_text(query)
                      .limit(10)
                      .pluck(:id, :title, :address, :price)
                      .map do |id, title, address, price|
      {
        id: id,
        title: title,
        address: address,
        price: price,
        label: "#{title} - #{address}"
      }
    end
    
    render json: results
  end
  
  # GET /properties/compare
  def compare
    property_ids = session[:comparison_ids] || []
    @properties = Property.published.where(id: property_ids).limit(4)
    
    if @properties.empty?
      redirect_to properties_path, alert: 'Добавьте объекты для сравнения'
      return
    end
    
    track_event('properties_compared', { property_ids: property_ids })
  end
  
  # POST /properties/add_to_compare
  def add_to_compare
    session[:comparison_ids] ||= []
    session[:comparison_ids] << params[:id].to_i
    session[:comparison_ids].uniq!
    
    render json: { 
      success: true, 
      count: session[:comparison_ids].count,
      message: 'Объект добавлен в сравнение'
    }
  end
  
  # DELETE /properties/remove_from_compare
  def remove_from_compare
    session[:comparison_ids] ||= []
    session[:comparison_ids].delete(params[:id].to_i)
    
    render json: { 
      success: true, 
      count: session[:comparison_ids].count,
      message: 'Объект удален из сравнения'
    }
  end
  
  # ============================================
  # MEMBER ACTIONS
  # ============================================
  
  # POST /properties/:id/favorite
  def favorite
    current_user.favorite(@property)
    
    track_event('property_favorited', { property_id: @property.id })
    
    respond_to do |format|
      format.html { redirect_back fallback_location: @property, notice: 'Добавлено в избранное' }
      format.json { render json: { success: true, favorited: true } }
    end
  end
  
  # DELETE /properties/:id/unfavorite
  def unfavorite
    current_user.unfavorite(@property)
    
    track_event('property_unfavorited', { property_id: @property.id })
    
    respond_to do |format|
      format.html { redirect_back fallback_location: @property, notice: 'Удалено из избранного' }
      format.json { render json: { success: true, favorited: false } }
    end
  end
  
  # POST /properties/:id/schedule_viewing
  def schedule_viewing
    @viewing = ViewingSchedule.new(
      property: @property,
      user: current_user,
      preferred_date: params[:preferred_date],
      preferred_time: params[:preferred_time],
      message: params[:message]
    )
    
    if @viewing.save
      track_event('viewing_scheduled', { property_id: @property.id })
      
      redirect_to @property, notice: 'Заявка на просмотр отправлена'
    else
      redirect_to @property, alert: 'Ошибка при отправке заявки'
    end
  end
  
  # GET /properties/:id/share
  def share
    respond_to do |format|
      format.html { redirect_to @property }
      format.json do
        render json: {
          url: property_url(@property),
          title: @property.title,
          description: @property.short_description,
          image: @property.primary_image&.url
        }
      end
    end
  end
  
  # GET /properties/:id/print
  def print
    render layout: 'print'
  end

  # GET /properties/:id/dossier.pdf
  # A3 — premium-gated PDF dossier (5 страниц: cover/gallery/description/
  # agent/cta). Returns 403-style redirect для non-premium объектов чтобы
  # не палить сам endpoint, но и не палить dossier-template для бюджет-сегмента.
  def dossier
    unless @property.premium?
      redirect_to @property, alert: 'Дозсье доступно только для премиум-объектов.' and return
    end

    pdf_bytes = PropertyDossierPdfGenerator.call(@property, locale: :ru)
    filename  = "dossier-#{@property.try(:slug) || @property.id}.pdf"
    send_data pdf_bytes,
              filename: filename,
              type: 'application/pdf',
              disposition: params[:download] == '1' ? 'attachment' : 'inline'
  rescue StandardError => e
    Rails.logger.warn("[PropertiesController#dossier] #{e.class}: #{e.message}")
    redirect_to @property, alert: 'PDF временно недоступен, попробуйте через минуту.'
  end
  
  # POST /properties/:id/report
  def report
    # Report inappropriate content
    reason = params[:reason]
    description = params[:description]
    
    # Send to admins or create a report record
    AdminMailer.property_reported(@property, current_user, reason, description).deliver_later
    
    track_event('property_reported', { 
      property_id: @property.id, 
      reason: reason 
    })
    
    redirect_to @property, notice: 'Жалоба отправлена. Спасибо за информацию!'
  end
  
  private
  
  # ============================================
  # CALLBACKS
  # ============================================
  
  def set_property
    @property = Property.friendly.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to properties_path, alert: 'Объект недвижимости не найден'
  end
  
  def authorize_property
    unless @property.user == current_user || current_user&.admin?
      redirect_to @property, alert: 'У вас нет прав для выполнения этого действия'
    end
  end
  
  def set_per_page
    @per_page = per_page
  end
  
  # ============================================
  # STRONG PARAMETERS
  # ============================================
  
  def property_params
    params.require(:property).permit(
      :title, :description, :price, :deal_type, :property_type_id,
      :area, :living_area, :kitchen_area,
      :rooms, :bedrooms, :bathrooms,
      :floor, :total_floors,
      :building_year, :building_type, :condition,
      :address, :district, :metro_station, :metro_distance, :metro_transport,
      :has_balcony, :has_loggia, :has_parking, :has_elevator,
      :has_garbage_chute, :has_security, :has_concierge, :pets_allowed,
      :has_gas, :has_water, :has_electricity, :has_heating,
      :ceiling_height, :window_view, :furniture, :appliances,
      :ownership_type, :owners_count, :encumbrance, :mortgage_allowed,
      :video_url, :virtual_tour_url,
      :meta_title, :meta_description, :meta_keywords,
      images: [],
      floor_plans: []
    )
  end
  
  # ============================================
  # HELPERS
  # ============================================
  
  def sort_order
    case params[:sort]
    when 'price_asc'
      { price: :asc }
    when 'price_desc'
      { price: :desc }
    when 'area_asc'
      { area: :asc }
    when 'area_desc'
      { area: :desc }
    when 'date_asc'
      { created_at: :asc }
    when 'date_desc', nil
      { created_at: :desc }
    else
      { created_at: :desc }
    end
  end
  
  def calculate_map_center
    if params[:lat].present? && params[:lng].present?
      [params[:lat].to_f, params[:lng].to_f]
    elsif @properties.any?
      avg_lat = @properties.average(:latitude).to_f
      avg_lng = @properties.average(:longitude).to_f
      [avg_lat, avg_lng]
    else
      [55.7558, 37.6173] # Moscow coordinates as default
    end
  end
  
  def set_property_meta_tags
    image_url = primary_image_absolute_url
    set_meta_tags(
      title: @property.title,
      description: @property.short_description(160),
      keywords: property_keywords,
      og: {
        title: @property.title,
        description: @property.short_description(200),
        image: image_url,
        url: property_url(@property),
        type: 'product'
      }.compact,
      twitter: {
        card: 'summary_large_image',
        title: @property.title,
        description: @property.short_description(200),
        image: image_url
      }.compact
    )
  end

  # Active Storage attachments don't have `.url`; we need rails_blob_url.
  # Returns absolute URL or nil (let meta_tags omit the field).
  def primary_image_absolute_url
    blob = @property.primary_image
    return nil if blob.blank?
    Rails.application.routes.url_helpers.rails_blob_url(blob, host: request.base_url)
  rescue StandardError => e
    Rails.logger.warn("[Property##{@property.id}] primary image URL failed: #{e.class} #{e.message}")
    nil
  end
  
  def property_keywords
    keywords = [@property.property_type&.name, @property.district]
    keywords << "#{@property.rooms}-комнатная" if @property.rooms
    keywords << I18n.t("activerecord.attributes.property.deal_types.#{@property.deal_type}", default: @property.deal_type)
    keywords.compact.join(', ')
  end
  
  # ============================================
  # JSON RESPONSES
  # ============================================
  
  def properties_json
    {
      properties: @properties.map { |p| property_summary(p) },
      meta: {
        current_page: @properties.current_page,
        total_pages: @properties.total_pages,
        total_count: @total_count,
        per_page: @per_page
      }
    }
  end
  
  def property_detail_json
    {
      id: @property.id,
      title: @property.title,
      description: @property.description,
      price: @property.price,
      price_formatted: @property.price_formatted,
      price_per_sqm: @property.price_per_sqm,
      area: @property.area,
      rooms: @property.rooms,
      floor: @property.floor,
      total_floors: @property.total_floors,
      address: @property.address,
      coordinates: {
        lat: @property.latitude,
        lng: @property.longitude
      },
      images: @property.image_urls,
      similar_properties: @similar_properties.map { |p| property_summary(p) }
    }
  end
  
  def map_properties_json
    {
      properties: @properties.map do |p|
        {
          id: p.id,
          title: p.title,
          price: p.price,
          price_formatted: p.price_formatted,
          coordinates: {
            lat: p.latitude,
            lng: p.longitude
          },
          url: property_path(p)
        }
      end,
      center: @map_center,
      zoom: @map_zoom
    }
  end
  
  def property_summary(property)
    {
      id: property.id,
      title: property.title,
      price: property.price,
      price_formatted: property.price_formatted,
      area: property.area,
      rooms: property.rooms,
      address: property.address,
      district: property.district,
      url: property_path(property),
      image_url: property.primary_image&.url,
      is_featured: property.is_featured
    }
  end
end