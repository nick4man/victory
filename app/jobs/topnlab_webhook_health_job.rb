# frozen_string_literal: true

# Phase 4E — Silent webhook failure detection.
#
# Topnlab может silently stop sending webhooks (config change, network issue,
# их side bug). Без external monitoring мы узнаем только через retroactive
# inquiry sync mismatch.
#
# Cron daily 08:00 MSK: проверяем Redis 'topnlab:last_webhook_at'. Если
# > THRESHOLD ago → CriticalRecipients alert.
#
# Threshold 24h — Topnlab имеет постоянный поток (orders changes daily),
# silence > 24h = anomaly.
class TopnlabWebhookHealthJob < ApplicationJob
  queue_as :scheduled

  SILENCE_THRESHOLD = 24.hours
  ALERT_THROTTLE_KEY = 'topnlab_webhook_silent'

  def perform
    last_at_str = read_last_webhook_at
    last_at = parse_time(last_at_str)

    if last_at.nil?
      Rails.logger.warn(
        '[TopnlabWebhookHealthJob] no last_webhook_at recorded — webhook never seen ' \
        'OR Redis flushed (acceptable on fresh deploy). Skipping alert.'
      )
      return :no_data
    end

    age = Time.current - last_at
    if age < SILENCE_THRESHOLD
      Rails.logger.info("[TopnlabWebhookHealthJob] OK — last webhook #{(age / 60).round}min ago")
      return :ok
    end

    Rails.logger.warn(
      "[TopnlabWebhookHealthJob] SILENT — last webhook #{(age / 3600).round(1)}h ago, threshold #{SILENCE_THRESHOLD / 3600}h"
    )
    alert_directors(last_at, age)
    :alerted
  end

  private

  def read_last_webhook_at
    require 'redis' unless defined?(Redis)
    Redis.new(url: ENV.fetch('REDIS_URL', 'redis://redis:6379/0'))
         .get('topnlab:last_webhook_at')
  rescue StandardError => e
    Rails.logger.warn("[TopnlabWebhookHealthJob] redis read: #{e.message}")
    nil
  end

  def parse_time(str)
    return nil if str.blank?

    Time.zone.parse(str.to_s)
  rescue ArgumentError
    nil
  end

  def alert_directors(last_at, age)
    return unless Telegram::AlertThrottle.allow?(key: ALERT_THROTTLE_KEY)

    cascade = Telegram::CriticalRecipients.resolve
    tier_note = cascade.fallback? ? "\n<i>(routed to #{cascade.tier} tier — directors недоступны)</i>" : ''

    text = "🔇 <b>Topnlab webhook silence</b>\n" \
           "Последний webhook: #{last_at.strftime('%d.%m.%y %H:%M')}\n" \
           "Молчание: <b>#{(age / 3600).round(1)}ч</b> (порог #{SILENCE_THRESHOLD / 3600}ч)\n\n" \
           '<i>Возможные причины:\n' \
           '  • Topnlab config — webhook URL изменился/отключён\n' \
           '  • Network — наш endpoint недоступен for Topnlab\n' \
           '  • Topnlab API outage</i>' + tier_note

    client = Telegram::Client.new
    cascade.each do |recipient|
      chat_id = recipient.dm_chat_id || recipient.tg_user_id
      next if chat_id.blank?

      client.send_message(text, chat_id: chat_id, parse_mode: 'HTML')
    rescue StandardError => e
      Rails.logger.warn("[TopnlabWebhookHealthJob] DM to #{recipient.mention}: #{e.message}")
    end
  end
end
