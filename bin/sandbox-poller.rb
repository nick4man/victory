# frozen_string_literal: true

# Опрос тестового бота: getUpdates → тот же InboundProcessorJob, что и вебхук.
# Нужен только песочнице в Codespace, где публичного адреса нет (см.
# bin/sandbox-codespace). В проде апдейты приходят вебхуком.
token = ENV.fetch('TELEGRAM_TEST_BOT_TOKEN')
offset = nil
Rails.logger.info('[sandbox-poller] старт')
loop do
  uri = URI("https://api.telegram.org/bot#{token}/getUpdates")
  uri.query = URI.encode_www_form({ timeout: 25, offset: offset }.compact)
  body = Net::HTTP.get_response(uri).body
  updates = JSON.parse(body).fetch('result', [])
  updates.each do |update|
    offset = update['update_id'].to_i + 1
    Telegram::InboundProcessorJob.perform_async(update, 'test')
  end
rescue StandardError => e
  # Сеть моргнула или Telegram ответил мусором — ждём и пробуем снова: падать
  # песочнице незачем, перезапускать её некому.
  Rails.logger.warn("[sandbox-poller] #{e.class}: #{e.message}")
  sleep 5
end
