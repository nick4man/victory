# frozen_string_literal: true

# A7 Phase 2: client-side избранное. Idempotent toggle через
# POST /cabinet/favorites (находит или создаёт), DELETE remove.
#
# Auth: только cabinet_user_signed_in? с role=client.
# Agents/admins не имеют persistent избранного (они работают через
# Property.assigned_to scope).
#
# Toggle pattern:
#   POST /cabinet/favorites { property_id: X } → idempotent add
#   DELETE /cabinet/favorites/:property_id     → remove (idempotent — 200 если уже нет)
#
# Responds в html (для no-JS fallback с redirect) и turbo_stream
# (для inline heart-toggle без перезагрузки).
class Cabinet::FavoritesController < ApplicationController
  before_action :require_client_cabinet_user

  def index
    @favorites = @cabinet_user.favorites.includes(:property).recent
    @properties = @favorites.map(&:property).compact.reject(&:deleted?)
  end

  def create
    property = Property.unscoped.find_by(id: params[:property_id])
    return head :not_found unless property

    fav = @cabinet_user.favorites.find_or_create_by(property: property)
    respond_to do |fmt|
      fmt.turbo_stream { render turbo_stream: turbo_replace_button(property, favorited: true) }
      fmt.html         { redirect_back fallback_location: property_path(property), notice: 'Добавлено в избранное' }
      fmt.json         { render json: { status: 'ok', favorited: true, property_id: property.id, favorite_id: fav.id } }
    end
  end

  def destroy
    property = Property.unscoped.find_by(id: params[:id])
    return head :not_found unless property

    @cabinet_user.favorites.where(property_id: property.id).destroy_all
    respond_to do |fmt|
      fmt.turbo_stream { render turbo_stream: turbo_replace_button(property, favorited: false) }
      fmt.html         { redirect_back fallback_location: cabinet_favorites_path, notice: 'Удалено из избранного' }
      fmt.json         { render json: { status: 'ok', favorited: false, property_id: property.id } }
    end
  end

  private

  def require_client_cabinet_user
    @cabinet_user = current_cabinet_user
    return if @cabinet_user&.role_client?

    redirect_to cabinet_login_path, alert: 'Доступ только для клиентов в личном кабинете.'
  end

  def turbo_replace_button(property, favorited:)
    turbo_stream.replace(
      "favorite-toggle-#{property.id}",
      partial: 'shared/favorite_toggle',
      locals:  { property: property, favorited: favorited }
    )
  end
end
