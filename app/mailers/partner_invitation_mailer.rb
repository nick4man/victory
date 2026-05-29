# frozen_string_literal: true

# Phase 3b — magic-link для partner portal /partners/login.
# Same SMTP infra (Mail.ru) как CabinetMailer; just different audience.
class PartnerInvitationMailer < ApplicationMailer
  def magic_link(agency, token)
    @agency = agency
    @url    = partners_verify_url(token: token.token)
    @expires_in_min = MagicLinkToken::TTL.in_minutes.to_i

    mail(
      to:      agency.contact_email,
      subject: "Вход в портал партнёра — #{AgencyInfo::NAME}"
    )
  end
end
