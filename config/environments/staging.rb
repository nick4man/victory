# frozen_string_literal: true

# Staging = production с послаблениями, перечисленными ниже. Всё остальное
# наследуется через require — дрейф двух конфигов исключён: правка
# production.rb действует на staging автоматически, пока её не переопределили
# здесь явно.
require_relative 'production'

Rails.application.configure do
  # Staging не должен слать почту реальным людям: письма складываются в
  # память (ActionMailer::TestHelper), SMTP не вызывается. SMTP_* в
  # .env.staging всё равно заглушки — это вторая линия.
  config.action_mailer.delivery_method = :test
  config.action_mailer.perform_deliveries = false

  # Свой namespace кэша — на случай, если staging когда-нибудь посмотрит в
  # боевой Redis (по умолчанию у staging свой контейнер redis, и это лишь
  # страховка).
  config.cache_store = :redis_cache_store, {
    url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'),
    namespace: 'viktory_realty_staging_cache',
    expires_in: 1.day,
    reconnect_attempts: 3
  }

  # force_ssl НЕ ослабляем: TLS терминирует Traefik роутера (сертификат
  # *.dev.victory62.org), внутренние /health и /webhooks/ и так исключены
  # в production.rb. DISABLE_SSL для staging не заводим.
end
