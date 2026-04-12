# frozen_string_literal: true

class Dashboard::InquiriesController < Dashboard::BaseController
  before_action :set_inquiry, only: [:show, :cancel, :timeline]

  def index
    @inquiries = current_user.inquiries.order(created_at: :desc)
  end

  def show
  end

  def cancel
    @inquiry.cancel! if @inquiry.respond_to?(:cancel!)
    redirect_to dashboard_inquiries_path, notice: 'Заявка отменена'
  end

  def timeline
    render :show
  end

  def destroy
    @inquiry = current_user.inquiries.find(params[:id])
    @inquiry.destroy
    redirect_to dashboard_inquiries_path, notice: 'Заявка удалена'
  end

  private

  def set_inquiry
    @inquiry = current_user.inquiries.find(params[:id])
  end
end
