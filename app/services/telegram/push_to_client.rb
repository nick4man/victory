# frozen_string_literal: true

module Telegram
  # Push notifications к клиенту в private DM с нашим ботом (@anvictorybot).
  # Используется как FREE-channel вместо SMS когда у клиента есть linked TG.
  #
  # Pre-condition: user.tg_user_id.present? (linkage происходит через
  # `ClientBot::LinkProcessor` после opt-in deep-link flow).
  #
  # Result struct compatible с Sms::SmscClient / Sms::SmsRuClient — это
  # позволяет drop-in dispatcher в CabinetInvitationDispatcher без if-else.
  class PushToClient
    Result = Struct.new(:success?, :message_id, :cost, :raw, :error,
                        keyword_init: true)

    # @param user [User]
    # @param message [String] plain text (HTML allowed; client сам поставит parse_mode)
    # @param parse_mode [String] 'HTML' / 'Markdown' / nil
    # @return [Result]
    def self.send(user:, message:, parse_mode: 'HTML')
      new(user, message, parse_mode).call
    end

    def initialize(user, message, parse_mode)
      @user       = user
      @message    = message
      @parse_mode = parse_mode
    end

    def call
      return skip('user nil') if @user.nil?
      return skip('tg not linked') if @user.tg_user_id.blank?
      return skip('message blank') if @message.to_s.strip.empty?

      result = Telegram::Client.new.send_message(
        @message,
        chat_id: @user.tg_user_id,
        parse_mode: @parse_mode,
        disable_web_page_preview: false # cabinet/property links должны preview'иться
      )

      Rails.logger.info(
        "[TGPush] sent user=#{@user.id} chat=#{@user.tg_user_id} msg_id=#{result['message_id']}"
      )
      Result.new(
        success?:   true,
        message_id: result['message_id'],
        cost:       0.0,           # FREE channel
        raw:        result
      )
    rescue Telegram::Client::Error => e
      # Common errors:
      #   "Forbidden: bot was blocked by the user" — user заблокировал бота.
      #     Это сигнал auto-unlink (см. ниже NOTE).
      #   "Bad Request: chat not found" — tg_user_id протух / пользователь
      #     удалил account. Тоже auto-unlink kandidат.
      should_unlink = blocked_error?(e.message) || chat_not_found?(e.message)
      auto_unlink!(reason: e.message.first(120)) if should_unlink

      Rails.logger.warn(
        "[TGPush] failed user=#{@user.id} chat=#{@user.tg_user_id} " \
        "error=#{e.message.first(160)} unlinked=#{should_unlink}"
      )
      Result.new(success?: false, error: e.message.first(160))
    rescue StandardError => e
      Rails.logger.warn("[TGPush] unexpected: #{e.class}: #{e.message.first(200)}")
      Sentry.capture_exception(e, extra: { user_id: @user&.id }) if defined?(Sentry)
      Result.new(success?: false, error: e.message.first(160))
    end

    private

    # NOTE: auto-unlink — если бот заблокирован, мы стираем tg_user_id
    # чтобы dispatcher НЕ пытался снова (бесполезно) и упал в SMS fallback.
    # При желании клиент сможет re-link через /cabinet/profile.
    def auto_unlink!(reason:)
      @user.update_columns(
        tg_user_id:   nil,
        tg_username:  nil,
        tg_linked_at: nil
      )
      Rails.logger.info("[TGPush] auto-unlinked user=#{@user.id}: #{reason}")
    end

    def blocked_error?(msg)
      msg.include?('bot was blocked') || msg.include?('user is deactivated')
    end

    def chat_not_found?(msg)
      msg.include?('chat not found')
    end

    def skip(reason)
      Rails.logger.info("[TGPush] user=#{@user&.id} skipped: #{reason}")
      Result.new(success?: false, error: reason)
    end
  end
end
