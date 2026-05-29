# frozen_string_literal: true

module Dashboard
  module Admin
    class ReportsController < Dashboard::BaseController
      before_action :require_admin!
      before_action :set_report, only: %i[show edit update destroy]

      def index
        @reports = CrmReport.order(:order_position, :title)
      end

      def new
        @report = CrmReport.new(active: true, order_position: 1)
      end

      def create
        @report = CrmReport.new(report_params)
        if @report.save
          push_to_crm(@report)
          redirect_to dashboard_admin_reports_path, notice: 'Отчёт зарегистрирован в CRM.'
        else
          render :new, status: :unprocessable_entity
        end
      end

      def edit; end

      def update
        if @report.update(report_params)
          update_in_crm(@report) if @report.crm_id
          redirect_to dashboard_admin_reports_path, notice: 'Отчёт обновлён.'
        else
          render :edit, status: :unprocessable_entity
        end
      end

      def destroy
        delete_from_crm(@report) if @report.crm_id
        @report.destroy
        redirect_to dashboard_admin_reports_path, notice: 'Отчёт удалён.'
      end

      private

      def set_report
        @report = CrmReport.find(params[:id])
      end

      def report_params
        params.require(:crm_report).permit(:title, :slug, :page_id, :order_position, :template_class, :active)
      end

      def push_to_crm(report)
        result = Topnlab::Client.new.create_report_menu(
          title:        report.title,
          page_id:      report.page_id,
          order:        report.order_position,
          callback_url: report.callback_url
        )
        report.update(crm_id: extract_id(result), synced_at: Time.current) if result
      rescue Topnlab::Client::Error => e
        Rails.logger.warn("[Reports] create failed: #{e.message}")
      end

      def update_in_crm(report)
        Topnlab::Client.new.update_report_menu(id: report.crm_id, title: report.title, order: report.order_position)
        report.update(synced_at: Time.current)
      rescue Topnlab::Client::Error => e
        Rails.logger.warn("[Reports] update failed: #{e.message}")
      end

      def delete_from_crm(report)
        Topnlab::Client.new.delete_report_menu(id: report.crm_id)
      rescue Topnlab::Client::Error => e
        Rails.logger.warn("[Reports] delete failed: #{e.message}")
      end

      def extract_id(payload)
        return nil unless payload.is_a?(Hash)
        payload['id'] || payload.dig('data', 'id')
      end

      def require_admin!
        redirect_to root_path, alert: 'Раздел доступен только администратору.' unless current_user.role_admin?
      end
    end
  end
end
