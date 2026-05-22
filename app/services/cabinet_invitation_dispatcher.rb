# frozen_string_literal: true

# #413e — Channel-priority dispatch для cabinet invitations.
#
# Centralizes the email→TG→SMS chain so OwnerSyncService и future caller'ы
# (admin manual «отправить приглашение», cron'ы реактивации) не дублируют
# логику.
#
# Channel priority (cheapest reliable channel first):
#   1. EMAIL    — CabinetInvitationMailer.deliver_later (FREE, rich HTML)
#   2. TELEGRAM — CabinetInvitationTgService (FREE, link preview)
#   3. SMS      — Sms::Client through CabinetInvitationSmsService (~1.5 ₽)
#
# #413f update: OwnerSyncService теперь вызывает с channels: %i[email tg]
# (БЕЗ sms) — auto-onboarding только через бесплатные channels. SMS-branch
# остаётся в коде ТОЛЬКО для admin manual triggers (defer to future).
# Phone-only клиенты Topnlab активируются через inbound trigger
# (ClientBot::ActivationRequestProcessor) или admin-shared QR/link
# (/admin/users/:id).
#
# Idempotency: gate на user.invited_at.nil? — каждый channel сам выставит
# invited_at on success (или дисптачер пометит сам после email queue).
#
# Failure-isolation: rescue StandardError везде так что error в одном
# channel не сломает остальные.
class CabinetInvitationDispatcher
  Result = Struct.new(:channels_attempted, :channels_succeeded, :errors,
                      keyword_init: true)

  # @param user [User]
  # @param property [Property, nil] контекст объекта (для message)
  # @param channels [Array<Symbol>] override порядок/набор (по умолч %i[email tg sms])
  #                                  Используется в тестах или для админ-force через SMS
  def self.call(user, property = nil, channels: %i[email tg sms])
    new(user, property, channels).call
  end

  def initialize(user, property, channels)
    @user      = user
    @property  = property
    @channels  = channels
    @attempted = []
    @succeeded = []
    @errors    = []
  end

  def call
    return short_circuit('user nil') if @user.nil?
    return short_circuit('already invited') if @user.invited_at.present?
    return short_circuit('phone in stop-list') if blocked_phone?

    @channels.each do |channel|
      case channel
      when :email then try_email
      when :tg    then try_telegram
      when :sms   then try_sms
      end
      # Если хотя бы один channel succeeded — мы invited. Не шлём дубли.
      break if @succeeded.any?
    end

    Rails.logger.info(
      "[InvitationDispatcher] user=#{@user.id} " \
      "attempted=#{@attempted.inspect} succeeded=#{@succeeded.inspect} errors=#{@errors.size}"
    )
    Result.new(channels_attempted: @attempted, channels_succeeded: @succeeded, errors: @errors)
  end

  private

  def try_email
    return unless @user.email.present?
    # #435 — respect user preferences. Cabinet invitation = deal_events
    # (это onboarding в сделку через property linkage).
    return unless @user.notify?(category: 'deal_events', channel: 'email')

    @attempted << :email
    CabinetInvitationMailer.invite(@user, @property).deliver_later
    @user.update_columns(invited_at: Time.current)
    @succeeded << :email
    Rails.logger.info(
      "[InvitationDispatcher] email queued user=#{@user.id} " \
      "email=#{mask_email(@user.email)} property=#{@property&.id}"
    )
  rescue StandardError => e
    @errors << "email: #{e.class}: #{e.message.first(120)}"
    Rails.logger.warn("[InvitationDispatcher] email failed user=#{@user.id}: #{e.class}: #{e.message.first(160)}")
    Sentry.capture_exception(e, extra: { user_id: @user.id, channel: 'email' }) if defined?(Sentry)
  end

  def try_telegram
    return unless @user.tg_user_id.present?
    return unless @user.notify?(category: 'deal_events', channel: 'tg')

    @attempted << :tg
    result = CabinetInvitationTgService.call(@user, @property)
    if result.success?
      @succeeded << :tg
    else
      @errors << "tg: #{result.error}"
    end
  rescue StandardError => e
    @errors << "tg: #{e.class}: #{e.message.first(120)}"
    Rails.logger.warn("[InvitationDispatcher] tg failed user=#{@user.id}: #{e.class}: #{e.message.first(160)}")
    Sentry.capture_exception(e, extra: { user_id: @user.id, channel: 'tg' }) if defined?(Sentry)
  end

  def try_sms
    return unless @user.phone.present?
    return unless @user.notify?(category: 'deal_events', channel: 'sms')

    @attempted << :sms
    result = CabinetInvitationSmsService.call(@user, @property)
    if result.success?
      @succeeded << :sms
    else
      @errors << "sms: #{result.error}"
    end
  rescue StandardError => e
    @errors << "sms: #{e.class}: #{e.message.first(120)}"
    Rails.logger.warn("[InvitationDispatcher] sms failed user=#{@user.id}: #{e.class}: #{e.message.first(160)}")
    Sentry.capture_exception(e, extra: { user_id: @user.id, channel: 'sms' }) if defined?(Sentry)
  end

  def short_circuit(reason)
    Rails.logger.info("[InvitationDispatcher] short-circuit: #{reason}")
    Result.new(channels_attempted: [], channels_succeeded: [], errors: [reason])
  end

  # 152-ФЗ stop-list pre-flight: проверяет user.phone против PhoneStopList.
  # Если phone в registry — НЕ инициируем НИКАКОЙ outbound channel (даже
  # email — клиент мог отозвать ВСЯКОЕ согласие, не только SMS).
  def blocked_phone?
    return false if @user.phone.blank?
    PhoneStopList.blocked?(@user.phone)
  end

  def mask_email(email)
    parts = email.to_s.split('@')
    return '***' if parts.size != 2
    "#{parts.first[0..1]}***@#{parts.last}"
  end
end
