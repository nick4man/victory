# frozen_string_literal: true

# Public-facing consent verification endpoint. QR-код в PDF договора
# ведёт сюда — любой может проверить что договор подписан и
# не tampered. PII НЕ показываем (имя/контакты клиента скрыты).
#
# Reveals only:
#   - Property title + address (already public listing data)
#   - Signed_at, consent_version
#   - Tamper-check status (hash matches stored)
#   - Revocation status (если revoked — показываем)
class PublicConsentsController < ApplicationController
  def show
    @consent = ListingConsent.find_by(token: params[:token])
    return render :not_found, status: :not_found unless @consent

    @tampered = !@consent.tamper_check
    @property = @consent.property
  end
end
