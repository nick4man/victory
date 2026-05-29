# frozen_string_literal: true

# Phase 15 polish (Pillar 1) — unified «Все мои документы» view для cabinet.
# Сейчас документы разбросаны: ListingConsent PDFs доступны per-property
# (/cabinet/listings/:id/consent.pdf), ClientDocument scans live in cabinet
# но без back-download link, valuations PDFs не были привязаны. Этот
# controller агрегирует ВСЕ document-like artifacts клиента в один список.
#
# UI pattern: card per document с metadata (kind, status, date) + action
# (preview/download/track). Reuses /cabinet/listings/:id/consent.pdf для
# consent downloads — no new PDF generators.
#
# Auth: session[:cabinet_user_id] required (как другие cabinet/* controllers).
class Cabinet::DocumentsController < ApplicationController
  before_action :require_cabinet_user

  def index
    @signed_consents = ListingConsent.where(user_id: @cabinet_user.id)
                                     .where.not(signed_at: nil)
                                     .includes(:property)
                                     .order(signed_at: :desc)
                                     .limit(50)

    @client_documents = ClientDocument.where(uploader_id: @cabinet_user.id)
                                      .where.not(status: :archived)
                                      .order(created_at: :desc)
                                      .limit(50)

    @valuations = PropertyValuation.where(user_id: @cabinet_user.id)
                                   .or(PropertyValuation.where('LOWER(email) = ?', @cabinet_user.email.to_s.downcase))
                                   .order(created_at: :desc)
                                   .limit(20)
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
