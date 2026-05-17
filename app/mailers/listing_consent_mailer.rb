# frozen_string_literal: true

# A7 Phase 3: emails для consent workflow.
# - consent_required: agent создал Property → email клиенту с magic-link
#   на /cabinet/listings/:id/consent
# - signed_confirmation: после подписания, копия в email клиенту для
#   архива + ссылка на верификацию /verify-contract/:token
class ListingConsentMailer < ApplicationMailer
  # Triggered когда Property.status flips → pending_consent
  # @param property [Property]
  # @param user [User] — client, который должен подписать
  def consent_required(property, user)
    @property = property
    @user = user

    # Generate single-use magic-link для прямого захода в /cabinet/listings/:id/consent
    token = MagicLinkToken.generate!(
      identifier: user.email,
      identifier_type: 'email'
    )
    @login_url = cabinet_verify_url(token: token.token)
    @consent_url = cabinet_listing_consent_url(property)

    mail(
      to:      user.email,
      subject: "Требуется ваше согласие на публикацию — #{AgencyInfo::NAME}"
    )
  end

  # Triggered после успешного signing
  # @param consent [ListingConsent]
  def signed_confirmation(consent)
    @consent = consent
    @property = consent.property
    @user = consent.user
    @verify_url = verify_contract_url(token: consent.token)

    mail(
      to:      @user.email,
      subject: "Договор № #{consent.id} подписан — #{AgencyInfo::NAME}"
    )
  end
end
