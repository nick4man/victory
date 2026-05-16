# frozen_string_literal: true

# Personal cabinet entry point. Dispatches на client view (Inquiries +
# PVs + CaseStudies + Favorites + Deal status) или staff view
# (assigned Inquiries + own Properties) на основе current_cabinet_user.role.
#
# Auth: magic-link через Cabinet::AuthController. Без сессии → redirect
# на /cabinet/login.
#
# CLAUDE rule 8: НЕ Devise. session[:cabinet_user_id] хранит User.id,
# nothing else.
class CabinetController < ApplicationController
  before_action :require_cabinet_user

  def index
    case @cabinet_user.role.to_s
    when 'client'         then render 'cabinet/clients/index'
    when 'agent', 'admin' then render 'cabinet/staff/index'
    else
      session.delete(:cabinet_user_id)
      redirect_to cabinet_login_path, alert: 'Доступ запрещён. Свяжитесь с агентством.'
    end
  end

  # A7 Phase 2: JSON-эндпоинт для polling в кабинете. ActionCable JS
  # инфра отключена в проекте (см. valuation_progress_controller.js
  # комменты), поэтому "real-time" реализован через client-side polling
  # на этот endpoint (5s cadence). CabinetChannel broadcasts всё равно
  # запускаются — они активируются когда JS infra будет wire'нута.
  def status
    email = @cabinet_user.email.to_s.downcase
    phone_digits = @cabinet_user.phone.to_s.gsub(/\D/, '').last(10)

    inquiries_scope = Inquiry.where(user_id: @cabinet_user.id)
                             .or(Inquiry.where('LOWER(email) = ?', email))
    if phone_digits.length == 10
      inquiries_scope = inquiries_scope.or(Inquiry.where('phone LIKE ?', "%#{phone_digits}"))
    end

    valuations_scope = PropertyValuation.where(user_id: @cabinet_user.id)
                                        .or(PropertyValuation.where('LOWER(email) = ?', email))
    if phone_digits.length == 10
      valuations_scope = valuations_scope.or(PropertyValuation.where('phone LIKE ?', "%#{phone_digits}"))
    end

    render json: {
      ts:                Time.current.to_i,
      inquiries: inquiries_scope.order(updated_at: :desc).limit(20).map { |i|
        { id: i.id, status: i.status, priority: i.priority, updated_at: i.updated_at.iso8601 }
      },
      valuations: valuations_scope.order(updated_at: :desc).limit(20).map { |v|
        { id: v.id, token: v.token, status: v.status, estimated_price: v.estimated_price, updated_at: v.updated_at.iso8601 }
      }
    }
  end

  private

  def require_cabinet_user
    @cabinet_user = User.find_by(id: session[:cabinet_user_id], active: true, deleted_at: nil)
    return if @cabinet_user

    session.delete(:cabinet_user_id)
    redirect_to cabinet_login_path, alert: 'Сначала войдите в кабинет.'
  end

  helper_method :cabinet_user
  def cabinet_user
    @cabinet_user
  end
end
