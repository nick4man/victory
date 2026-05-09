# frozen_string_literal: true

module Dashboard
  class OrdersController < BaseController
    before_action :require_staff!
    before_action :set_order, only: %i[show]

    def index
      @scope = BuyerOrder.includes(:user)
      @scope = @scope.active unless params[:show_archived] == '1'
      @scope = @scope.realty_type_eq(params[:realty_type])
      @scope = @scope.deal_type_eq(params[:deal_type])
      @scope = @scope.for_district(params[:district])
      @scope = @scope.for_city(params[:city])
      @scope = @scope.within_price(params[:price_min].to_i, params[:price_max].to_i) if params[:price_min].present? || params[:price_max].present?
      @scope = @scope.for_agent(current_user.id) if params[:my_only] == '1'
      @scope = @scope.recent

      @orders = @scope.page(params[:page]).per(20)
      @total = @scope.except(:offset, :limit).count
      @realty_types = BuyerOrder.where.not(realty_type: nil).distinct.pluck(:realty_type).sort
      @cities = BuyerOrder.where('preferred_cities IS NOT NULL').pluck(:preferred_cities).flatten.uniq.compact_blank.sort.first(50)
    end

    def show
      @matches = @order.matching_properties(limit: 12)
      @notes = @order.notes.order(created_at: :desc) if @order.respond_to?(:notes)
    end

    private

    def set_order
      @order = BuyerOrder.find(params[:id])
    end

    def require_staff!
      redirect_to root_path, alert: 'Раздел доступен только сотрудникам.' unless current_user.role_agent? || current_user.role_admin?
    end
  end
end
