# frozen_string_literal: true

class Dashboard::FavoritesController < Dashboard::BaseController
  def index
    @favorites = current_user.favorites.includes(property: :property_type).order(created_at: :desc)
    @properties = @favorites.map(&:property).compact
  end

  def destroy
    favorite = current_user.favorites.find(params[:id])
    favorite.destroy
    redirect_to dashboard_favorites_path, notice: 'Удалено из избранного'
  end

  def clear_all
    current_user.favorites.destroy_all
    redirect_to dashboard_favorites_path, notice: 'Избранное очищено'
  end

  def export
    @properties = current_user.favorites.includes(property: :property_type).map(&:property).compact
    respond_to do |format|
      format.html
      format.json { render json: @properties }
    end
  end
end
