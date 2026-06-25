# frozen_string_literal: true

# Rails Helper for RSpec - АН "Виктори"

require 'spec_helper'
ENV['RAILS_ENV'] ||= 'test'
require_relative '../config/environment'

# Prevent database truncation if the environment is production
abort("The Rails environment is running in production mode!") if Rails.env.production?

require 'rspec/rails'
# Add additional requires below this line. Rails is not loaded until this point!
require 'factory_bot_rails'
require 'faker'
require 'shoulda/matchers'
require 'database_cleaner/active_record'
require 'capybara/rspec'
require 'pundit/rspec'
require 'webmock/rspec'

# WebMock: allow real net by default (specs которые бьют реальные сервисы не
# ломаем), но stub_request перехватывает явно застабленные запросы. Specs,
# требующие полной изоляции (yandex_vision/client), сами вызывают stub_request.
WebMock.allow_net_connect!

# Requires supporting ruby files with custom matchers and macros, etc, in
# spec/support/ and its subdirectories.
Dir[Rails.root.join('spec/support/**/*.rb')].sort.each { |f| require f }

# Checks for pending migrations and applies them before tests are run.
begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  abort e.to_s.strip
end

RSpec.configure do |config|
  # Remove this line if you're not using ActiveRecord or ActiveRecord fixtures
  config.fixture_path = Rails.root.join('spec/fixtures')

  # If you're not using ActiveRecord, or you'd prefer not to run each of your
  # examples within a transaction, remove the following line or assign false
  config.use_transactional_fixtures = true

  # You can uncomment this line to turn off ActiveRecord support entirely.
  # config.use_active_record = false

  # RSpec Rails can automatically mix in different behaviours to your tests
  # based on their file location, for example enabling you to call `get` and
  # `post` in specs under `spec/controllers`.
  config.infer_spec_type_from_file_location!

  # Filter lines from Rails gems in backtraces.
  config.filter_rails_from_backtrace!
  # arbitrary gems may also be filtered via:
  # config.filter_gems_from_backtrace("gem name")

  # Include FactoryBot methods
  config.include FactoryBot::Syntax::Methods

  # Iter 61 — TimeHelpers project-wide (travel_to / travel / freeze_time).
  # Rails 7 не auto-include для RSpec; нужно явно. Используется в любых
  # specs где тестируется TTL / scheduled-at / expires_at / etc.
  config.include ActiveSupport::Testing::TimeHelpers

  # Include Devise test helpers
  config.include Devise::Test::ControllerHelpers, type: :controller
  config.include Devise::Test::IntegrationHelpers, type: :request
  config.include Warden::Test::Helpers

  # Database Cleaner configuration
  config.before(:suite) do
    DatabaseCleaner.clean_with(:truncation)
  end

  config.before(:each) do
    DatabaseCleaner.strategy = :transaction
  end

  config.before(:each, js: true) do
    DatabaseCleaner.strategy = :truncation
  end

  config.before(:each) do
    DatabaseCleaner.start
  end

  config.after(:each) do
    DatabaseCleaner.clean
  end

  # Warden helpers
  config.after(:each) do
    Warden.test_reset!
  end

  # Capybara configuration
  Capybara.default_driver = :rack_test
  Capybara.javascript_driver = :selenium_chrome_headless
end

# Shoulda Matchers Configuration
Shoulda::Matchers.configure do |config|
  config.integrate do |with|
    with.test_framework :rspec
    with.library :rails
  end
end

# Faker locale
Faker::Config.locale = 'ru'

