# frozen_string_literal: true

module Services
  # Mortgage application flow — receives leads from:
  #   1. /services/mortgage_calculator/programs/:id/apply  (calc → click row)
  #   2. /services/mortgage_calculator/programs/:id/apply?audit_token=…
  #      (audit result page → "Оформить заявку" per row, B.3 cross-link)
  #   3. Direct visit to /services/mortgage_applications/new
  #
  # Creates an Inquiry(inquiry_type: 'mortgage') with rich metadata so staff
  # can route to the correct bank-partner channel. Notifies Telegram +
  # email via MortgageApplicationNotifier.
  class MortgageApplicationsController < ApplicationController
    def new
      @program          = lookup_program(params[:id] || params[:program_id])
      @audit_valuation  = lookup_audit(params[:audit_token])
      @inquiry          = Inquiry.new(prefilled_attrs)
    end

    def create
      @program = lookup_program(params[:program_id])
      @inquiry = Inquiry.new(mortgage_inquiry_params.merge(
        inquiry_type: 'mortgage',
        status: 'new',
        ip_address: request.remote_ip,
        user_agent: request.user_agent
      ))
      @inquiry.metadata = build_metadata.merge(@inquiry.metadata || {})

      if @inquiry.save
        MortgageApplicationNotifier.notify(@inquiry, @program)
        flash[:notice] = "Заявка №#{@inquiry.id} принята. Менеджер свяжется с вами в течение часа."
        redirect_to services_mortgage_application_path(@inquiry)
      else
        @audit_valuation = lookup_audit(params[:audit_token])
        render :new, status: :unprocessable_entity
      end
    end

    def show
      @inquiry = Inquiry.find(params[:id])
      @program = lookup_program(@inquiry.metadata&.dig('program_id'))
    end

    def status
      @inquiry = Inquiry.find(params[:id])
      render json: { status: @inquiry.status, updated_at: @inquiry.updated_at }
    end

    private

    def lookup_program(id)
      return nil if id.blank?
      Mortgage::ProgramsService.find(id)
    end

    def lookup_audit(token)
      return nil if token.blank?
      PropertyValuation.find_by(token: token)
    end

    def prefilled_attrs
      v = lookup_audit(params[:audit_token])
      return {} unless v
      {
        name: v.name,
        phone: v.phone,
        email: v.email,
        metadata: {
          property_price: v.estimated_price,
          property_address: v.address,
          audit_token: v.token,
          audit_report_number: v.report_number
        }.compact_blank
      }
    end

    def mortgage_inquiry_params
      params.require(:inquiry).permit(
        :name, :phone, :email, :message,
        metadata: %i[property_price down_payment loan_term monthly_income]
      )
    end

    def build_metadata
      meta = {}
      if @program
        meta[:program_id]      = @program[:id]
        meta[:program_bank]    = @program[:bank_name]
        meta[:program_product] = @program[:product_name]
        meta[:program_rate]    = @program[:rate_min]
      end
      meta[:audit_token] = params[:audit_token] if params[:audit_token].present?
      meta
    end
  end
end
