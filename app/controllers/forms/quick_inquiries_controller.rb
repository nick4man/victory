# frozen_string_literal: true

class Forms::QuickInquiriesController < ApplicationController
  def create
    @inquiry = Inquiry.new(quick_inquiry_params)
    @inquiry.user = current_user if current_user
    @inquiry.ip_address = request.remote_ip

    if @inquiry.save
      InquiryMailer.new_inquiry(@inquiry).deliver_later rescue nil
      render json: { success: true, message: 'Заявка отправлена. Мы свяжемся с вами!' }
    else
      render json: { success: false, errors: @inquiry.errors.full_messages }, status: :unprocessable_entity
    end
  end

  private

  def quick_inquiry_params
    params.require(:inquiry).permit(:name, :phone, :email, :message, :property_id, :inquiry_type)
  end
end
