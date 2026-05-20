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

  # Phase 14 Iter 58 — sync native /-меню (setMyCommands).
  # Запускать после: deploy с изменением каталога команд, добавлением нового staff,
  # промоут/демоут существующего staff (на случай если реактивный hook не отработал).
  desc 'Sync native TG /-меню: global scopes + per-user (BotCommandScopeChat) для всех staff с dm_chat_id'
  task sync_commands: :environment do
    sync = Telegram::WorkBot::CommandsMenuSync.new
    sync.sync_global!
    puts '[OK] global scopes synced (default + all_group_chats)'

    count = 0
    TelegramUser.where.not(dm_chat_id: nil).find_each do |u|
      sync.sync_for_user!(u)
      count += 1
      puts "[OK] user##{u.id} #{u.display_name.ljust(25)} role=#{u.role} status=#{u.status}"
    rescue StandardError => e
      puts "[FAIL] user##{u.id} #{u.display_name}: #{e.class} #{e.message}"
    end
    puts "Done. #{count} users synced."
  end
end
