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

    desc 'Webhook тестового бота (песочница карточек CRM): только message и callback_query.'
    task setup_test: :environment do
      test_token = ENV.fetch('TELEGRAM_TEST_BOT_TOKEN', nil)
      main_token = ENV.fetch('TELEGRAM_BOT_TOKEN', nil)
      # Оба токена должны быть заданы и различаться — иначе setWebhook либо
      # упадёт с непонятной ошибкой Telegram, либо (что хуже) молча перепишет
      # вебхук боевого бота на тестовый URL, если токены случайно совпали.
      if test_token.blank? || main_token.blank? || test_token == main_token
        abort('[telegram:webhook:setup_test] TELEGRAM_TEST_BOT_TOKEN и TELEGRAM_BOT_TOKEN должны быть ' \
              'заданы и отличаться друг от друга — иначе тестовый вебхук либо не встанет, либо тихо ' \
              'перепишет боевой. API не вызван.')
      end

      url = ENV.fetch('TELEGRAM_TEST_WEBHOOK_URL')
      secret = ENV.fetch('TELEGRAM_TEST_WEBHOOK_SECRET')
      # Регистрируется URL relay-воркера (tg-webhook-relay/src/index.js), а не
      # прямой путь Rails: TG-диапазоны блокирует firewall на хосте (см.
      # docstring воркера), напрямую до /webhooks/telegram_test TG не достучится.
      # Воркер отличает тестовый бот от основного строго по pathname == '/test'
      # (см. `isTest = new URL(request.url).pathname === '/test'` в index.js) —
      # любой другой путь форвардится на основной эндпоинт бота-боёвика.
      # Прямой путь Rails тоже допустим: тестовый контроллер сам закрыт секретом.
      unless URI(url).path == '/test' || URI(url).path.end_with?('/webhooks/telegram_test')
        abort("[telegram:webhook:setup_test] TELEGRAM_TEST_WEBHOOK_URL=#{url} — путь должен " \
              'быть ровно /test (эндпоинт relay-воркера для тестового бота): любой другой путь ' \
              'воркер форвардит на основной эндпоинт. API не вызван.')
      end

      result = Telegram::BotContext.within('test') do
        Telegram::Client.new.set_webhook(url, secret_token: secret, allowed_updates: %w[message callback_query],
                                              drop_pending_updates: true)
      end
      puts "setWebhook (test) result: #{result.inspect}"
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
