# frozen_string_literal: true

module Dashboard
  class NotesController < BaseController
    before_action :require_staff!
    before_action :set_notable

    def create
      note = @notable.notes.build(
        user: current_user,
        note: params[:note].to_s.strip,
        sync_state: 'pending',
        crm_entity_type: derive_type
      )
      if note.note.present? && note.save
        TopnlabNotePushJob.perform_later(note.id) if @notable.respond_to?(:crm_id) && @notable.crm_id.present?
        redirect_back fallback_location: dashboard_root_path, notice: 'Заметка добавлена и отправляется в CRM.'
      else
        redirect_back fallback_location: dashboard_root_path, alert: 'Не удалось сохранить заметку.'
      end
    end

    private

    def set_notable
      type = params[:notable_type].to_s
      id   = params[:notable_id].to_i
      klass = { 'property' => Property, 'buyer_order' => BuyerOrder, 'service_order' => ServiceOrder }[type]
      raise ActiveRecord::RecordNotFound, "Unknown notable type #{type}" unless klass
      @notable = klass.find(id)
    end

    def derive_type
      case @notable
      when Property     then 'realty'
      when BuyerOrder   then 'order'
      when ServiceOrder then 'service'
      end
    end

    def require_staff!
      redirect_to root_path, alert: 'Раздел доступен только сотрудникам.' unless current_user.role_agent? || current_user.role_admin?
    end
  end
end
