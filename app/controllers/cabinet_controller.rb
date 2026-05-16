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
