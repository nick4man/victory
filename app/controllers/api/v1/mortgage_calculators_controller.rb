# frozen_string_literal: true

module Api
  module V1
    class MortgageCalculatorsController < BaseController
      skip_before_action :authenticate_api_user!, only: [:calculate]

      def calculate
        principal = params[:principal].to_f
        annual_rate = params[:rate].to_f / 100.0
        months = params[:term].to_i * 12
        return render_bad_request('principal/rate/term required') if principal <= 0 || months <= 0

        monthly_rate = annual_rate / 12.0
        payment =
          if monthly_rate.zero?
            principal / months
          else
            principal * (monthly_rate * (1 + monthly_rate)**months) / ((1 + monthly_rate)**months - 1)
          end

        render_success({
          monthly_payment: payment.round(2),
          total: (payment * months).round(2),
          overpayment: (payment * months - principal).round(2)
        })
      end
    end
  end
end
