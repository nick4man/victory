# frozen_string_literal: true

class Services::MortgageCalculatorsController < ApplicationController
  def show
  end

  def calculate
    amount = params[:amount].to_f
    down_payment = params[:down_payment].to_f
    rate = params[:rate].to_f / 100 / 12
    term_months = params[:term_years].to_i * 12

    loan_amount = amount - down_payment

    if rate > 0 && term_months > 0 && loan_amount > 0
      monthly_payment = loan_amount * rate * (1 + rate)**term_months / ((1 + rate)**term_months - 1)
      total_payment = monthly_payment * term_months
      overpayment = total_payment - loan_amount
    else
      monthly_payment = 0
      total_payment = 0
      overpayment = 0
    end

    render json: {
      monthly_payment: monthly_payment.round(2),
      total_payment: total_payment.round(2),
      overpayment: overpayment.round(2),
      loan_amount: loan_amount.round(2)
    }
  end

  def banks
    render json: { banks: [] }
  end

  def programs
    render json: { programs: [] }
  end
end
