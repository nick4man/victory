# frozen_string_literal: true

# D3 — Client invitation email при CRM-linked owner создании.
# Когда Topnlab::OwnerSyncService находит нового client'a и создаёт
# User(role=:client) с email — мы отправляем «вам привязан объект,
# войдите в кабинет» email с magic-link.
#
# Distinct от UserMailer.welcome_email (generic «welcome to site»)
# потому что context специфичный: client возможно даже не знает что
# мы есть, и попадает в кабинет «после факта» (объект уже залистинг).
class CabinetInvitationMailer < ApplicationMailer
  def invite(user, property = nil)
    @user = user
    @property = property
    @magic_link = generate_magic_link_for(user)
    @cabinet_url = build_cabinet_url

    mail(
      to: user.email,
      subject: invitation_subject
    )
  end

  private

  def invitation_subject
    if @property&.address.present?
      "Ваш объект на сайте АН «Виктори» — #{@property.address.truncate(40)}"
    else
      "Личный кабинет на сайте АН «Виктори»"
    end
  end

  # Single-use 30-min magic-link → /cabinet/verify/<token>.
  # Re-uses MagicLinkToken model (scope='login' default).
  def generate_magic_link_for(user)
    token = MagicLinkToken.generate!(
      identifier:      user.email,
      identifier_type: 'email',
      scope:           'login',
      request:         nil
    )
    "#{ENV.fetch('APP_URL', 'https://victory62.org')}/cabinet/verify/#{token.token}"
  end

  def build_cabinet_url
    "#{ENV.fetch('APP_URL', 'https://victory62.org')}/cabinet/properties"
  end
end
