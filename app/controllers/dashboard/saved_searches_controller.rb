# frozen_string_literal: true

class Dashboard::SavedSearchesController < Dashboard::BaseController
  before_action :set_saved_search, only: [:show, :destroy, :activate, :deactivate, :results, :run]

  def index
    @saved_searches = current_user.saved_searches.order(created_at: :desc)
  end

  def show
  end

  def destroy
    @saved_search.destroy
    redirect_to dashboard_saved_searches_path, notice: 'Сохранённый поиск удалён'
  end

  def activate
    @saved_search.update(active: true)
    redirect_to dashboard_saved_searches_path, notice: 'Поиск активирован'
  end

  def deactivate
    @saved_search.update(active: false)
    redirect_to dashboard_saved_searches_path, notice: 'Поиск деактивирован'
  end

  def results
    @properties = Property.published.ransack(@saved_search.filters).result.limit(20)
    render :show
  end

  def run
    results
  end

  private

  def set_saved_search
    @saved_search = current_user.saved_searches.find(params[:id])
  end
end
