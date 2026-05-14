# frozen_string_literal: true

# Rake-команды для управления Telegram-webhook'ом.
# См. https://core.telegram.org/bots/api#setwebhook
namespace :telegram do
  namespace :webhook do
    desc 'Set webhook URL + allowed_updates (включая Phase 3 message_reaction).'
    task setup: :environment do
      raw_host = ENV.fetch('APP_HOST', 'https://victory62.org')
      # Защищаемся от APP_HOST без схемы — иначе Telegram примет невалидный URL.
      host = raw_host.start_with?('http://', 'https://') ? raw_host : "https://#{raw_host}"
      url  = ENV.fetch('TELEGRAM_WEBHOOK_URL', "#{host}/webhooks/telegram")
      token = ENV.fetch('TELEGRAM_WEBHOOK_SECRET', nil)

      allowed = [
        'message',
        'edited_message',
        'callback_query',
        'message_reaction',       # Phase 3 — реакции 👍/🔥/✅ как ack-сигнал
        'message_reaction_count', # Phase 3 — агрегированные счётчики (опц)
        'my_chat_member',
        'chat_member',
        'forum_topic_created',
        'forum_topic_edited'
      ].freeze

      Rails.logger.info("[telegram:webhook:setup] url=#{url} allowed=#{allowed.inspect}")
      client = Telegram::Client.new

      result = client.set_webhook(
        url,
        secret_token: token,
        allowed_updates: allowed,
        drop_pending_updates: false
      )
      puts "setWebhook result: #{result.inspect}"
    end

    desc 'Show current webhook info (URL, allowed_updates, pending_update_count).'
    task info: :environment do
      info = Telegram::Client.new.webhook_info
      puts JSON.pretty_generate(info)
    end

    desc 'Delete webhook (для перехода в polling mode).'
    task delete: :environment do
      result = Telegram::Client.new.delete_webhook
      puts "deleteWebhook result: #{result.inspect}"
    end
  end
end
