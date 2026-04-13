# frozen_string_literal: true

source 'https://rubygems.org'
git_source(:github) { |repo| "https://github.com/#{repo}.git" }

ruby '~> 3.2'

# Core Rails
gem 'rails', '~> 7.1.0'

# Database
gem 'pg', '~> 1.5'

# Server
gem 'puma', '~> 6.4'

# Assets
gem 'sprockets-rails'
gem 'importmap-rails'
gem 'stimulus-rails'
gem 'turbo-rails'
gem 'jbuilder'

# CSS
gem 'tailwindcss-rails', '~> 3.3.1'

# Minimal auth  
gem 'bcrypt', '~> 3.1.7'

# Pagination
gem 'kaminari', '~> 1.2'

# API
gem 'rack-cors', '~> 2.0'

# Performance
gem 'bootsnap', require: false
gem 'friendly_id', '~> 5.5'
gem 'pg_search', '~> 2.3'
gem 'geocoder', '~> 1.8'

gem "devise", "~> 5.0"
gem "devise-i18n", "~> 1.12"

gem "omniauth", "~> 2.1"
gem "omniauth-google-oauth2", "~> 1.1"
# omniauth-yandex несовместим с omniauth 2.x, используем кастомную стратегию
# gem "omniauth-yandex"
gem "omniauth-rails_csrf_protection", "~> 1.0"

gem "aasm", "~> 5.5"

# Search & filtering
gem 'ransack', '~> 4.1'

# Authorization
gem 'pundit', '~> 2.3'

# Admin panel
gem 'activeadmin', '~> 3.2'
gem 'sassc-rails', '~> 2.1'

# JWT for API authentication
gem 'jwt', '~> 2.7'

# Background jobs
gem 'sidekiq', '~> 7.3'
gem 'sidekiq-cron', '~> 1.12'

# Redis (for Sidekiq and cache store)
gem 'redis', '~> 5.0'

# Cron scheduling
gem 'whenever', '~> 1.0', require: false

# Testing
group :development, :test do
  gem 'rspec-rails', '~> 6.1'
  gem 'factory_bot_rails', '~> 6.4'
  gem 'faker', '~> 3.2'
  gem 'database_cleaner-active_record', '~> 2.1'
end

group :test do
  gem 'shoulda-matchers', '~> 6.0'
  gem 'capybara', '~> 3.39'
end

group :development do
  gem 'annotate', '~> 3.2'
  gem 'letter_opener', '~> 1.10'
end
