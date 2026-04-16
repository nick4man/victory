# frozen_string_literal: true

class Api::V1::SavedSearchesController < Api::V1::BaseController
  before_action :authenticate_api_user!
  before_action :set_saved_search, only: [:show, :update, :destroy]

  def index
    searches = current_api_user.saved_searches.order(created_at: :desc)
    render_success(searches.map { |s| { id: s.id, name: s.name, filters: s.filters } })
  end

  def show
    render_success(id: @saved_search.id, name: @saved_search.name, filters: @saved_search.filters)
  end

  def create
    search = current_api_user.saved_searches.build(saved_search_params)
    if search.save
      render_success({ id: search.id, name: search.name }, status: :created)
    else
      render_error(search.errors.full_messages.join(', '), status: :unprocessable_entity)
    end
  end

  def update
    if @saved_search.update(saved_search_params)
      render_success(id: @saved_search.id, name: @saved_search.name)
    else
      render_error(@saved_search.errors.full_messages.join(', '), status: :unprocessable_entity)
    end
  end

  def destroy
    @saved_search.destroy
    render_success(message: 'Поиск удалён')
  end

  private

  def set_saved_search
    @saved_search = current_api_user.saved_searches.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_error('Не найдено', status: :not_found)
  end

  def saved_search_params
    params.require(:saved_search).permit(:name, :active, filters: {})
  end
end
