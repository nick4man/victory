# frozen_string_literal: true

module Dashboard
  # Agent's personal property pipeline: every Property assigned to current_user,
  # regardless of CRM deal_state. Filters by stage so an agent can pick "в рекламе" /
  # "в работе" / "архив" subsets.
  class PropertiesController < BaseController
    before_action :require_staff!

    def index
      @scope = Property.unscoped.assigned_to(current_user).where(deleted_at: nil)
      @scope = @scope.where(deal_state: params[:deal_state]) if params[:deal_state].present?
      @scope = @scope.where(deal_type: params[:deal_type]) if params[:deal_type].present?
      @scope = @scope.where(property_type_id: params[:property_type_id]) if params[:property_type_id].present?
      @scope = @scope.order(updated_at: :desc)

      @properties = @scope.includes(:property_type, images_attachments: :blob).page(params[:page]).per(20)
      @counts = Property.unscoped.assigned_to(current_user).where(deleted_at: nil).group(:deal_state).count
    end

    # POST /dashboard/properties/:id/sync_from_crm — re-pull the card from
    # Topnlab through the same job the webhook uses. After import the job
    # also runs publish_if_ready! so status reflects the latest CRM flags.
    def sync_from_crm
      property = Property.unscoped.assigned_to(current_user).find(params[:id])
      if property.external_id.present?
        TopnlabPropertyImportJob.perform_later(property.external_id)
        redirect_to dashboard_properties_path,
                    notice: "Запрошена синхронизация ##{property.external_id}. Обновится через минуту."
      else
        redirect_to dashboard_properties_path, alert: 'У объекта нет CRM-идентификатора.'
      end
    end

    private

    def require_staff!
      redirect_to root_path, alert: 'Раздел доступен только сотрудникам.' unless current_user.role_agent? || current_user.role_admin?
    end
  end
end
