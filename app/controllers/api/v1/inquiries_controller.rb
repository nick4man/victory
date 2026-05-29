# frozen_string_literal: true

module Api
  module V1
    class InquiriesController < BaseController
      def index
        inquiries = paginate(current_api_user.inquiries.order(created_at: :desc))
        render_success(inquiries.map { |i| serialize(i) }, meta: pagination_meta(inquiries))
      end

      def show
        inquiry = current_api_user.inquiries.find(params[:id])
        render_success(serialize(inquiry))
      end

      def create
        inquiry = current_api_user.inquiries.new(inquiry_params)
        if inquiry.save
          render_created(serialize(inquiry))
        else
          render_error('Validation failed', errors: inquiry.errors.full_messages)
        end
      end

      private

      def inquiry_params
        params.require(:inquiry).permit(:property_id, :name, :phone, :email, :message, :inquiry_type)
      end

      def serialize(i)
        {
          id: i.id,
          property_id: i.property_id,
          name: i.name,
          phone: i.phone,
          email: i.email,
          message: i.message,
          status: i.status,
          created_at: i.created_at
        }
      end
    end
  end
end
