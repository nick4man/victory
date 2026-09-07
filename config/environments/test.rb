# frozen_string_literal: true

require 'active_support/core_ext/integer/time'

# The test environment is used exclusively to run your application's
# test suite. You never need to work with it otherwise. Remember that
# your test database is "scratch space" for the test suite and is wiped
# and recreated between test runs. Don't rely on the data there!

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Turn false under Spring and add config.action_view.cache_template_loading = true.
  config.cache_classes = true

  # Eager loading loads your whole application. When running a single test locally,
  # this probably isn't necessary. It's a good idea to do in a continuous integration
  # system, or in some way before deploying your code.
  config.eager_load = ENV['CI'].present?

  # Configure public file server for tests with Cache-Control for performance.
  config.public_file_server.enabled = true
  config.public_file_server.headers = {
    'Cache-Control' => "public, max-age=#{1.hour.to_i}"
  }

  # Show full error reports and disable caching.
  config.consider_all_requests_local       = true
  config.action_controller.perform_caching = false
  config.cache_store = :null_store

  # ActiveJob — in-memory очередь вместо Sidekiq.
  #
  # config/application.rb:46 ставит :sidekiq для ВСЕХ сред, включая test, и
  # нигде не выставлен Sidekiq::Testing. Из-за этого спеки писали задания в
  # настоящий Redis: один прогон spec/models/property_spec.rb добавлял 19 job'ов
  # в queue:default (after_commit в property.rb дёргает Seo::IndexNowNotifyJob и
  # Yandex::RecrawlUrlJob, а в транзакционных тестах Rails after_commit
  # выполняется). Задания при этом никогда не исполнялись — воркера нет, — но
  # копились между прогонами: к моменту находки в очереди лежало 226 штук.
  #
  # Следствия: сьют зависел от доступности Redis и накапливал состояние, а это
  # источник недетерминизма (seo видел плавающее число падений на одном наборе).
  #
  # Смена адаптера безопасна: ни один спек не использует have_enqueued_job,
  # perform_enqueued_jobs или Sidekiq::Worker — проверено грепом.
  config.active_job.queue_adapter = :test

  # Raise exceptions instead of rendering exception templates.
  config.action_dispatch.show_exceptions = false

  # Disable request forgery protection in test environment.
  config.action_controller.allow_forgery_protection = false

  # Store uploaded files on the local file system in a temporary directory.
  config.active_storage.service = :test

  # ActionMailer configuration for tests
  config.action_mailer.perform_caching = false

  # Tell Action Mailer not to deliver emails to the real world.
  # The :test delivery method accumulates sent emails in the
  # ActionMailer::Base.deliveries array.
  config.action_mailer.delivery_method = :test
  config.action_mailer.perform_deliveries = true
  
  # Default URL options for tests
  config.action_mailer.default_url_options = {
    host: 'test.host',
    port: 3000
  }
  
  config.action_mailer.asset_host = 'http://test.host'

  # Print deprecation notices to the stderr.
  config.active_support.deprecation = :stderr

  # Raise exceptions for disallowed deprecations.
  config.active_support.disallowed_deprecation = :raise

  # Tell Active Support which deprecation messages to disallow.
  config.active_support.disallowed_deprecation_warnings = []

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  # config.action_view.annotate_rendered_view_with_filenames = true

  # ActionCable configuration for tests
  config.action_cable.disable_request_forgery_protection = true

  # Tailwind собирается на деплое, `app/assets/builds/*` в git не хранится
  # (.gitignore:63). Без этого любой request-спек, рендерящий layout, падал
  # бы 500 на `stylesheet_link_tag "tailwind"` — и локально, и в CI, где
  # ассеты тоже не собираются. Тестам CSS не нужен: пусть Sprockets отдаёт
  # путь как есть вместо исключения.
  #
  # Цена принята сознательно: fallback-ветка в sprockets-rails 3.5.2
  # помечена deprecated и однажды будет удалена, а опечатка в имени ассета
  # больше не уронит request-спек. Альтернатива — собирать ассеты перед
  # прогоном — добавляет шаг, о котором надо помнить и локально, и в CI;
  # забытый шаг даёт 500, никак не связанный с правкой. Наличие ассетов —
  # вопрос деплоя, там и проверяется.
  config.assets.unknown_asset_fallback = true
end

