# frozen_string_literal: true

# D3 fallback: client invitation via SMS when no email.
# Companion to CabinetInvitationMailer.
#
# Logic mirror'ит mailer:
#   1. Gate: phone.present? AND user.invited_at.nil?
#   2. Generate magic-link (same MagicLinkToken pattern, 30min single-use)
#   3. Compose SMS body (короткое, Cyrillic-friendly)
#   4. Send through Sms::SmscClient
#   5. On success — update_columns(invited_at: Time.current)
#
# Caller: Topnlab::OwnerSyncService#send_cabinet_invitation —
# выбирает email-first, fallback to SMS if email blank.
class CabinetInvitationSmsService
  Result = Struct.new(:success?, :user, :sms_id, :cost, :error, keyword_init: true)

  def self.call(user, property = nil)
    new(user, property).call
  end

  def initialize(user, property = nil)
    @user = user
    @property = property
  end

  def call
    return skip('phone blank') if @user.phone.blank?
    return skip('already invited') unless @user.invited_at.nil?

    token = MagicLinkToken.generate!(
      identifier:      @user.phone,
      identifier_type: 'phone',
      scope:           'login',
      request:         nil
    )
    link = "#{ENV.fetch('APP_URL', 'https://victory62.org')}/cabinet/verify/#{token.token}"

    message = build_message(link)
    # Provider-agnostic router (ENV['SMS_PROVIDER']: smsru / smsc).
    # Default 'smsru' — ~40-50% дешевле SMSC при том же coverage.
    result  = Sms::Client.send(phone: @user.phone, message: message)

    if result.success?
      @user.update_columns(invited_at: Time.current)
      Rails.logger.info(
        "[CabinetInvitationSms] sent user=#{@user.id} phone=#{mask(@user.phone)} " \
        "sms_id=#{result.message_id} cost=#{result.cost}"
      )
      Result.new(success?: true, user: @user, sms_id: result.message_id, cost: result.cost)
    else
      Rails.logger.warn(
        "[CabinetInvitationSms] failed user=#{@user.id} phone=#{mask(@user.phone)} " \
        "error=#{result.error}"
      )
      Result.new(success?: false, user: @user, error: result.error)
    end
  rescue Sms::SmscClient::ConfigError, Sms::SmsRuClient::ConfigError => e
    Rails.logger.warn("[CabinetInvitationSms] config error — SMS skipped: #{e.message}")
    Result.new(success?: false, user: @user, error: 'sms not configured')
  rescue StandardError => e
    Rails.logger.warn("[CabinetInvitationSms] unexpected: #{e.class}: #{e.message.truncate(200)}")
    Result.new(success?: false, user: @user, error: e.message.truncate(160))
  end

  private

  # SMS limit (UTF-8 Cyrillic): 70 chars per segment, 67 if multi-segment.
  # Target: 2 segments max (~134 chars).
  def build_message(link)
    if @property&.address.present?
      "АН «Виктори»: к вашему объекту (#{@property.address.to_s.truncate(40)}) " \
        "привязан кабинет. Войти: #{link} (30 мин)"
    else
      "АН «Виктори»: ваш личный кабинет готов. Войти: #{link} (ссылка 30 мин)"
    end
  end

  # DLP — phone в логе только последние 4 цифры.
  def mask(phone)
    digits = phone.to_s.gsub(/\D/, '')
    return '****' if digits.length < 4
    "***#{digits.last(4)}"
  end

  def skip(reason)
    Rails.logger.info("[CabinetInvitationSms] user=#{@user.id} skipped: #{reason}")
    Result.new(success?: false, user: @user, error: reason)
  end
end
