# frozen_string_literal: true

module Dashboard
  # Stored property searches — user fills in a filter once, we save it, and
  # they can replay anytime + opt in to email alerts when new matching
  # listings appear.
  class SavedSearchesController < BaseController
    before_action :load_search, only: %i[show edit update destroy activate deactivate check_new]

    def index
      @saved_searches = current_user.saved_searches.order(Arel.sql('position NULLS LAST'), created_at: :desc)
    end

    def show
      # Run the filter against the live catalog so the user immediately sees
      # what their search currently matches.
      @matches = run_filter(@search).limit(50)
    end

    def new
      @search = current_user.saved_searches.new(active: true, notify_enabled: true)
    end

    def create
      @search = current_user.saved_searches.new(saved_search_attrs)
      if @search.save
        redirect_to dashboard_saved_search_path(@search), notice: 'Поиск сохранён.'
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit; end

    def update
      if @search.update(saved_search_attrs)
        redirect_to dashboard_saved_search_path(@search), notice: 'Сохранено.'
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @search.destroy
      redirect_to dashboard_saved_searches_path, notice: 'Поиск удалён.'
    end

    def activate
      @search.update(active: true)
      redirect_to dashboard_saved_searches_path, notice: 'Поиск активирован.'
    end

    def deactivate
      @search.update(active: false)
      redirect_to dashboard_saved_searches_path, notice: 'Поиск выключен.'
    end

    # POST /dashboard/saved_searches/:id/check_new — bumps last_checked_at
    # and recounts matches. JSON for any future polling-based UI.
    def check_new
      count = run_filter(@search).count
      @search.update(
        last_checked_at: Time.current,
        results_count: count,
        last_results_count_updated_at: Time.current
      )
      render json: { results_count: count, last_checked_at: @search.last_checked_at }
    end

    private

    def load_search
      @search = current_user.saved_searches.find(params[:id])
    end

    # Pull form fields, drop blanks, store as a flat hash. We write to BOTH
    # `filters` (new jsonb column) and `search_params` (legacy serialized
    # hash, still `presence: true` validated) so the record satisfies
    # validation and stays compatible with old code paths.
    def saved_search_attrs
      base = params.require(:saved_search).permit(:name, :description, :notify_enabled, :active, :notification_frequency)
      filter_keys = %i[deal_type property_type price_min price_max rooms district city]
      filters = params.require(:saved_search).permit(*filter_keys).to_h.reject { |_, v| v.blank? }
      base.merge(filters: filters, search_params: filters)
    end

    # Run the saved filter against the live, publishable catalog. Property
    # has no `city` column — we match it through `address` instead, since
    # CRM payloads include city as the first segment of the address string.
    def run_filter(search)
      filters = (search.filters || {}).symbolize_keys
      scope = Property.on_site
      scope = scope.where(deal_type: filters[:deal_type])                if filters[:deal_type].present?
      scope = scope.where(property_type_id: filters[:property_type])     if filters[:property_type].present?
      scope = scope.where('price >= ?', filters[:price_min].to_i)        if filters[:price_min].present?
      scope = scope.where('price <= ?', filters[:price_max].to_i)        if filters[:price_max].present?
      scope = scope.where(rooms: filters[:rooms])                        if filters[:rooms].present?
      scope = scope.where('district ILIKE ?', "%#{filters[:district]}%") if filters[:district].present?
      scope = scope.where('address ILIKE ?',  "%#{filters[:city]}%")     if filters[:city].present?
      scope.order(updated_at: :desc)
    end
  end
end
