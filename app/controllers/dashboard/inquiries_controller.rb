# frozen_string_literal: true

module Dashboard
  class InquiriesController < BaseController
    def index
      @inquiries = current_user.inquiries.order(created_at: :desc)
      render template: 'dashboard/inquiries'
    rescue StandardError
      render_coming_soon('Мои заявки', "Заявок: #{current_user.inquiries.count}")
    end

    def show
      @inquiry = current_user.inquiries.find(params[:id])
      render_coming_soon("Заявка ##{@inquiry.id}")
    end

    def destroy
      current_user.inquiries.find(params[:id]).destroy
      redirect_to dashboard_inquiries_path, notice: 'Заявка удалена.'
    end

    def cancel
      redirect_to dashboard_inquiries_path, notice: 'Заявка отменена.'
    end

    def timeline
      render_coming_soon('История заявки')
    end
  end
end
