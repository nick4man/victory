# frozen_string_literal: true

# Транзакционная почта для /cabinet flow (A7).
# Phase 1: magic-link для входа.
# Phase 2: status-update notifications (когда Inquiry меняется).
# Phase 3: consent-required (когда agent публикует listing).
class CabinetMailer < ApplicationMailer
  def magic_link(user, token)
    @user = user
    @url = cabinet_verify_url(token: token.token)
    @expires_in_min = MagicLinkToken::TTL.in_minutes.to_i

    mail(
      to:      user.email,
      subject: "Вход в личный кабинет — #{AgencyInfo::NAME}"
    )
  end
end
