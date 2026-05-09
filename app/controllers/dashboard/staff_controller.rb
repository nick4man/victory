# frozen_string_literal: true

module Dashboard
  class StaffController < BaseController
    before_action :require_staff!

    def index
      @search = params[:q].to_s.strip
      base = User.crm_active.includes(:department).order(:last_name, :first_name)

      if @search.present?
        like = "%#{ActiveRecord::Base.sanitize_sql_like(@search)}%"
        base = base.where(
          'LOWER(first_name) LIKE LOWER(?) OR LOWER(last_name) LIKE LOWER(?) OR ' \
          'LOWER(middle_name) LIKE LOWER(?) OR LOWER(email) LIKE LOWER(?) OR ' \
          'LOWER(crm_role_name) LIKE LOWER(?)',
          like, like, like, like, like
        )
        @users = base
        @grouped = nil
      else
        @users = base
        @grouped = base.group_by(&:department)
      end

      @departments = Department.active.includes(:users).ordered
    end

    private

    def require_staff!
      redirect_to root_path, alert: 'Раздел доступен только сотрудникам.' unless current_user.role_agent? || current_user.role_admin?
    end
  end
end
