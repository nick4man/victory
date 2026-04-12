# frozen_string_literal: true

class Dashboard::ComparisonsController < Dashboard::BaseController
  def index
    property_ids = session[:comparison_ids] || []
    @properties = Property.published.where(id: property_ids)
  end

  def destroy
    session[:comparison_ids] ||= []
    session[:comparison_ids].delete(params[:id].to_i)
    redirect_to dashboard_comparisons_path, notice: 'Объект удалён из сравнения'
  end

  def clear_all
    session[:comparison_ids] = []
    redirect_to dashboard_comparisons_path, notice: 'Список сравнения очищен'
  end
end
