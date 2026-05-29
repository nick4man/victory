# frozen_string_literal: true

# D3++ — Cabinet invitation via Telegram. FREE channel (0₽) — отправляется
# когда у клиента есть `user.tg_user_id` (см. #413a-c для opt-in flow).
#
# Mirrors `CabinetInvitationSmsService` API + idempotency rules:
#   1. Gate: user.tg_user_id.present? AND user.invited_at.nil?
#   2. Generate MagicLinkToken (login scope, 30min single-use)
#   3. Compose TG message (HTML parse_mode, может включать link preview)
#   4. Send through Telegram::PushToClient
#   5. On success — update_columns(invited_at: Time.current)
#
# Если PushToClient получит «Forbidden: bot was blocked» — он сам
# auto-unlink'нет tg_user_id (см. push_to_client.rb), и при следующем
# dispatch chain вернётся к SMS fallback.
#
# Caller: Cabinet::InvitationDispatcher (см. #413e).
class CabinetInvitationTgService
  Result = Struct.new(:success?, :user, :message_id, :cost, :error, keyword_init: true)

  def self.call(user, property = nil)
    new(user, property).call
  end

  def initialize(user, property = nil)
    @user = user
    @property = property
  end

  def call
    return skip('tg not linked') if @user.tg_user_id.blank?
    return skip('already invited') unless @user.invited_at.nil?

    token = MagicLinkToken.generate!(
      identifier:      (@user.email.presence || @user.phone.to_s),
      identifier_type: (@user.email.present? ? 'email' : 'phone'),
      scope:           'login',
      request:         nil
    )
    link    = "#{ENV.fetch('APP_URL', 'https://victory62.org')}/cabinet/verify/#{token.token}"
    message = build_message(link)

    result = Telegram::PushToClient.send(user: @user, message: message, parse_mode: 'HTML')

    if result.success?
      @user.update_columns(invited_at: Time.current)
      Rails.logger.info(
        "[CabinetInvitationTg] sent user=#{@user.id} msg_id=#{result.message_id}"
      )
      Result.new(success?: true, user: @user, message_id: result.message_id, cost: 0.0)
    else
      Rails.logger.warn(
        "[CabinetInvitationTg] failed user=#{@user.id} error=#{result.error}"
      )
      Result.new(success?: false, user: @user, error: result.error)
    end
  rescue StandardError => e
    Rails.logger.warn("[CabinetInvitationTg] unexpected: #{e.class}: #{e.message.first(200)}")
    Sentry.capture_exception(e, extra: { user_id: @user&.id }) if defined?(Sentry)
    Result.new(success?: false, user: @user, error: e.message.first(160))
  end

  private

  # TG message — HTML allowed, длина практически unlimited (до 4096 chars),
  # link previews включены. Богаче SMS, дешевле email.
  def build_message(link)
    address = @property&.address.to_s.truncate(80)
    intro = address.present? ? "к вашему объекту по адресу <b>#{address}</b>" : 'для вас'
    <<~MSG.strip
      🏡 <b>АН «Виктори»</b>

      Готов личный кабинет #{intro} — отслеживайте заявки, события сделки и документы.

      Вход (30 минут): #{link}
    MSG
  end

  def skip(reason)
    Rails.logger.info("[CabinetInvitationTg] user=#{@user.id} skipped: #{reason}")
    Result.new(success?: false, user: @user, error: reason)
  end
end
