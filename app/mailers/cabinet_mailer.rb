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

  # #434 — отправляет verify-link на НОВЫЙ email. Click → confirm_email_change
  # consume'нёт token + update user.email. Если письмо попало случайно
  # к чужому — обладание inbox'ом ничего не даёт, потому что
  # confirm проверяет `session[:pending_email_change_user_id]` (т.е.
  # клиент должен быть logged in С ТОГО ЖЕ устройства).
  def email_change_confirmation(user, new_email, token)
    @user = user
    @new_email = new_email
    @url = cabinet_confirm_email_change_url(token: token.token)
    @expires_in_min = MagicLinkToken::TTL.in_minutes.to_i

    mail(
      to:      new_email,
      subject: "Подтвердите новый email — #{AgencyInfo::NAME}"
    )
  end

  def password_reset(user, token)
    @user = user
    @url = edit_cabinet_password_url(token: token.token)
    @expires_in_min = MagicLinkToken::TTL.in_minutes.to_i

    mail(
      to:      user.email,
      subject: "Сброс пароля — #{AgencyInfo::NAME}"
    )
  end

  # D4 — деал-стадии: email клиенту при каждом stage transition.
  # Caller: Telegram::WorkBot::LeadStageTransition#notify_client_owner!
  # (feature-flagged через ENV['ENABLE_LEAD_STAGE_BROADCAST']).
  def stage_update(user, lead_event, prev_stage = nil)
    @user = user
    @lead = lead_event
    @prev_stage_label = Telegram::WorkBot::LeadStageTransition.stage_label(prev_stage) if prev_stage
    @new_stage_label  = Telegram::WorkBot::LeadStageTransition.stage_label(lead_event.current_stage)
    @cabinet_url      = "#{ENV.fetch('APP_URL', 'https://victory62.org')}/cabinet"

    mail(
      to:      user.email,
      subject: "Статус сделки обновлён: #{@new_stage_label} — #{AgencyInfo::NAME}"
    )
  end
end
