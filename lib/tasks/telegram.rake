# frozen_string_literal: true

namespace :telegram do
  desc 'Sanity check: who am I?'
  task get_me: :environment do
    puts JSON.pretty_generate(Telegram::Client.new.get_me)
  end

  desc 'Set webhook to https://APP_HOST/webhooks/telegram'
  task set_webhook: :environment do
    host = ENV['APP_HOST'].presence or abort('APP_HOST not set')
    url  = "https://#{host}/webhooks/telegram"
    result = Telegram::Client.new.set_webhook(url)
    puts "Set webhook → #{url}"
    puts JSON.pretty_generate(result.is_a?(Hash) ? result : { ok: result })
  end

  desc 'Inspect current webhook'
  task webhook_info: :environment do
    puts JSON.pretty_generate(Telegram::Client.new.webhook_info)
  end

  desc 'Drop the webhook (useful for switching dev/prod)'
  task delete_webhook: :environment do
    Telegram::Client.new.delete_webhook
    puts 'Webhook deleted.'
  end

  desc 'Send a test message to TELEGRAM_STAFF_CHAT_ID'
  task :test_message, [:text] => :environment do |_, args|
    chat_id = ENV['TELEGRAM_STAFF_CHAT_ID'].presence or abort('TELEGRAM_STAFF_CHAT_ID not set')
    text = args[:text].presence || "Тест из Rails — #{Time.current.strftime('%H:%M:%S')}"
    result = Telegram::Client.new.send_message(text, chat_id: chat_id)
    puts "Sent message_id=#{result['message_id']} to chat_id=#{result.dig('chat', 'id')}"
  end
end
