# frozen_string_literal: true

class InquiriesController < ApplicationController
  before_action :set_property

  def new
    @inquiry = @property.inquiries.build
  end

  def create
    @inquiry = @property.inquiries.build(inquiry_params)
    @inquiry.user = current_user if current_user
    @inquiry.ip_address = request.remote_ip
    @inquiry.user_agent = request.user_agent

    if @inquiry.save
      InquiryMailer.new_inquiry(@inquiry).deliver_later rescue nil
      respond_to do |format|
        format.html { redirect_to @property, notice: 'Ваша заявка отправлена. Мы свяжемся с вами!' }
        format.json { render json: { success: true, message: 'Заявка отправлена' } }
      end
    else
      respond_to do |format|
        format.html { redirect_to @property, alert: 'Ошибка при отправке заявки' }
        format.json { render json: { success: false, errors: @inquiry.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end

  private

  def set_property
    @property = Property.published.find(params[:property_id])
  rescue ActiveRecord::RecordNotFound
    redirect_to properties_path, alert: 'Объект не найден'
  end

  def inquiry_params
    params.require(:inquiry).permit(:name, :phone, :email, :message, :inquiry_type, :preferred_date)
  end
end
