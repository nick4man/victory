# frozen_string_literal: true

module Dashboard
  module Admin
    # Full property catalog for admin: any agent's objects, any state.
    # Reassign action: PATCH /dashboard/admin/properties/:id/assign — sets user_id.
    class PropertiesController < Dashboard::BaseController
      before_action :require_admin!

      def index
        @scope = Property.unscoped.where(deleted_at: nil).includes(:user, :property_type)
        @scope = @scope.where(deal_state: params[:deal_state]) if params[:deal_state].present?
        @scope = @scope.where(deal_type: params[:deal_type]) if params[:deal_type].present?
        @scope = @scope.assigned_to(params[:user_id]) if params[:user_id].present?
        @scope = @scope.unassigned if params[:unassigned] == '1'
        if params[:q].present?
          q = "%#{ActiveRecord::Base.sanitize_sql_like(params[:q])}%"
          @scope = @scope.where('LOWER(title) LIKE LOWER(?) OR LOWER(address) LIKE LOWER(?) OR external_id = ?', q, q, params[:q])
        end
        @scope = @scope.order(updated_at: :desc)

        @properties = @scope.page(params[:page]).per(30)
        @counts = Property.unscoped.where(deleted_at: nil).group(:deal_state).count
        @agents = User.where(role: %i[agent admin]).where(active: true).order(:last_name, :first_name)
      end

      def assign
        @property = Property.unscoped.find(params[:id])
        new_user_id = params[:user_id].presence
        @property.update_columns(user_id: new_user_id, updated_at: Time.current)

        respond_to do |format|
          format.html { redirect_back fallback_location: dashboard_admin_properties_path, notice: assignment_message(new_user_id) }
          format.json { render json: { ok: true, user_id: new_user_id } }
        end
      end

      private

      def assignment_message(uid)
        return 'Объект снят с агента.' if uid.blank?
        agent = User.find_by(id: uid)
        "Объект назначен агенту: #{agent&.short_name || "##{uid}"}."
      end

      def require_admin!
        redirect_to root_path, alert: 'Раздел доступен только администратору.' unless current_user.role_admin?
      end
    end
  end
end
