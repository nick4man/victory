# frozen_string_literal: true

module Api
  module V1
    class MortgageCalculatorController < BaseController
      skip_before_action :authenticate_api_user!

      # POST /api/v1/mortgage_calculator/calculate
      def calculate
        result = calculate_mortgage(mortgage_params)

        if result[:error]
          render_error(result[:error], status: :unprocessable_entity)
        else
          render_success(
            calculation: result,
            meta: api_response_meta
          )
        end
      end

      private

      def mortgage_params
        params.require(:mortgage).permit(
          :property_price, :down_payment, :loan_term_years, :annual_rate
        )
      end

      # rubocop:disable Metrics/MethodLength
      def calculate_mortgage(params)
        property_price  = params[:property_price].to_f
        down_payment    = params[:down_payment].to_f
        loan_term_years = params[:loan_term_years].to_i
        annual_rate     = params[:annual_rate].to_f

        # Validations
        return { error: 'Стоимость объекта должна быть больше 0' }       if property_price <= 0
        return { error: 'Первоначальный взнос не может быть отрицательным' } if down_payment.negative?
        return { error: 'Первоначальный взнос больше стоимости объекта' }  if down_payment >= property_price
        return { error: 'Срок кредита должен быть от 1 до 30 лет' }       unless (1..30).cover?(loan_term_years)
        return { error: 'Процентная ставка должна быть от 0.1 до 50%' }    unless (0.1..50.0).cover?(annual_rate)

        loan_amount      = property_price - down_payment
        monthly_rate     = annual_rate / 100.0 / 12.0
        total_months     = loan_term_years * 12
        down_payment_pct = (down_payment / property_price * 100).round(2)

        # Аннуитетный платёж: M = P * r * (1+r)^n / ((1+r)^n - 1)
        factor           = (1 + monthly_rate)**total_months
        monthly_payment  = loan_amount * monthly_rate * factor / (factor - 1)
        total_payment    = monthly_payment * total_months
        total_interest   = total_payment - loan_amount

        {
          property_price: property_price,
          down_payment: down_payment,
          down_payment_percent: down_payment_pct,
          loan_amount: loan_amount.round(2),
          loan_term_years: loan_term_years,
          loan_term_months: total_months,
          annual_rate: annual_rate,
          monthly_payment: monthly_payment.round(2),
          monthly_payment_formatted: format_rub(monthly_payment),
          total_payment: total_payment.round(2),
          total_payment_formatted: format_rub(total_payment),
          total_interest: total_interest.round(2),
          total_interest_formatted: format_rub(total_interest),
          overpayment_percent: (total_interest / loan_amount * 100).round(2)
        }
      end
      # rubocop:enable Metrics/MethodLength

      def format_rub(amount)
        "#{number_with_delimiter(amount.round(0).to_i, delimiter: ' ')} ₽"
      end

      def number_with_delimiter(number, delimiter: ' ')
        number.to_s.reverse.scan(/.{1,3}/).join(delimiter).reverse
      end
    end
  end
end
