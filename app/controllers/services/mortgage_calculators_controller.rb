# frozen_string_literal: true

module Services
  class MortgageCalculatorsController < ApplicationController
    include ComingSoonSection

    def show
      render_coming_soon('Ипотечный калькулятор', 'Рассчитайте ежемесячный платёж и переплату. Раздел подготавливается.')
    end

    def calculate
      principal = params[:principal].to_f
      annual_rate = params[:rate].to_f / 100.0
      months = params[:term].to_i * 12
      monthly_rate = annual_rate / 12.0
      payment =
        if monthly_rate.zero? || months.zero?
          months.zero? ? 0 : (principal / months)
        else
          principal * (monthly_rate * (1 + monthly_rate)**months) / ((1 + monthly_rate)**months - 1)
        end
      render json: {
        monthly_payment: payment.round(2),
        total: (payment * months).round(2),
        overpayment: (payment * months - principal).round(2)
      }
    end

    def banks
      render_coming_soon('Банки-партнёры')
    end

    def programs
      render_coming_soon('Программы кредитования')
    end
  end
end
