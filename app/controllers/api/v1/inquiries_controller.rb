# frozen_string_literal: true

module Api
  module V1
    class InquiriesController < BaseController
      # Allow unauthenticated users to create inquiries (public contact forms)
      skip_before_action :authenticate_api_user!, only: [:create]

      before_action :set_inquiry, only: [:show]

      # GET /api/v1/inquiries
      # Returns inquiries for the current user (client sees own, agent/admin sees assigned/all)
      def index
        @inquiries = scoped_inquiries.includes(:property, :agent).recent
        @inquiries = paginate(@inquiries)

        render_success(
          inquiries: serialize_inquiries(@inquiries),
          meta: pagination_meta(@inquiries).merge(api_response_meta)
        )
      end

      # GET /api/v1/inquiries/:id
      def show
        render_success(
          inquiry: serialize_inquiry_detail(@inquiry),
          meta: api_response_meta
        )
      end

      # POST /api/v1/inquiries
      def create
        @inquiry = Inquiry.new(inquiry_params)

        # Attach authenticated user if available
        @inquiry.user = current_api_user if current_api_user

        # Capture request metadata
        @inquiry.ip_address = request.remote_ip
        @inquiry.user_agent = request.user_agent
        @inquiry.source = 'api'

        if @inquiry.save
          render_created(
            serialize_inquiry(@inquiry),
            message: 'Заявка успешно создана'
          )
        else
          render_error(
            'Не удалось создать заявку',
            errors: @inquiry.errors.full_messages
          )
        end
      end

      private

      def set_inquiry
        @inquiry = scoped_inquiries.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render_not_found('Заявка не найдена')
      end

      def scoped_inquiries
        if current_api_user&.admin?
          Inquiry.all
        elsif current_api_user&.agent?
          Inquiry.where(agent_id: current_api_user.id)
                 .or(Inquiry.where(user_id: current_api_user.id))
        else
          Inquiry.where(user_id: current_api_user.id)
        end
      end

      def inquiry_params
        params.require(:inquiry).permit(
          :name, :phone, :email, :message,
          :inquiry_type, :property_id,
          :preferred_date, :preferred_time,
          :utm_source, :utm_medium, :utm_campaign
        )
      end

      def serialize_inquiries(inquiries)
        inquiries.map { |i| serialize_inquiry(i) }
      end

      def serialize_inquiry(inquiry)
        {
          id: inquiry.id,
          inquiry_type: inquiry.inquiry_type,
          status: inquiry.status,
          name: inquiry.name,
          phone: inquiry.formatted_phone,
          email: inquiry.email,
          property_id: inquiry.property_id,
          property_title: inquiry.property_title,
          created_at: inquiry.created_at
        }
      end

      def serialize_inquiry_detail(inquiry)
        serialize_inquiry(inquiry).merge(
          message: inquiry.message,
          preferred_date: inquiry.preferred_date,
          preferred_time: inquiry.preferred_time,
          scheduled_at: inquiry.scheduled_at,
          completed_at: inquiry.completed_at,
          agent: inquiry.agent ? {
            id: inquiry.agent.id,
            name: inquiry.agent.full_name,
            phone: inquiry.agent.formatted_phone
          } : nil,
          timeline: inquiry.timeline_events,
          updated_at: inquiry.updated_at
        )
      end
    end
  end
end
