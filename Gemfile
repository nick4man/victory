# frozen_string_literal: true

source 'https://rubygems.org'
git_source(:github) { |repo| "https://github.com/#{repo}.git" }

ruby '3.2.2'

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
gem 'tailwindcss-rails', '~> 2.0'

# Storage
gem 'redis', '~> 5.0'

# Background Jobs
gem 'sidekiq', '~> 7.2'

# Cron jobs
gem 'whenever', require: false

# Authentication & Authorization
gem 'devise', '~> 4.9'
gem 'omniauth-google-oauth2'
gem 'omniauth-yandex'
gem 'omniauth-rails_csrf_protection'
gem 'pundit', '~> 2.3'

# State Machine
gem 'aasm', '~> 5.5'

# Search
gem 'ransack', '~> 4.1'
gem 'pg_search', '~> 2.3'

# Pagination
gem 'kaminari', '~> 1.2'

# Forms
gem 'simple_form', '~> 5.3'

# File Upload
gem 'carrierwave', '~> 3.0'
gem 'mini_magick', '~> 4.12'

# Geocoding
gem 'geocoder', '~> 1.8'

# Admin Panel
gem 'activeadmin', '~> 3.2'
gem 'arctic_admin', '~> 4.2'

# PDF Generation
gem 'prawn', '~> 2.4'
gem 'prawn-table', '~> 0.2'

# Internationalization
gem 'rails-i18n', '~> 7.0'
gem 'devise-i18n', '~> 1.12'

# SEO & Sitemap
gem 'meta-tags', '~> 2.20'
gem 'sitemap_generator', '~> 6.3'
gem 'friendly_id', '~> 5.5'

# API
gem 'rack-cors', '~> 2.0'
gem 'rack-attack', '~> 6.7'

# Monitoring & Error Tracking
gem 'sentry-ruby', '~> 5.16'
gem 'sentry-rails', '~> 5.16'

# Performance
gem 'bootsnap', require: false

# Windows timezone data
gem 'tzinfo-data', platforms: %i[mingw mswin x64_mingw jruby]

group :development, :test do
  # Debugging
  gem 'debug', platforms: %i[mri mingw x64_mingw]
  gem 'pry-rails'
  gem 'pry-byebug'
  
  # Testing
  gem 'rspec-rails', '~> 6.1'
  gem 'factory_bot_rails', '~> 6.4'
  gem 'faker', '~> 3.2'
  
  # Code Quality
  gem 'rubocop', '~> 1.60', require: false
  gem 'rubocop-rails', '~> 2.23', require: false
  gem 'rubocop-rspec', '~> 2.26', require: false
  gem 'rubocop-performance', '~> 1.20', require: false
  
  # Environment variables
  gem 'dotenv-rails', '~> 3.0'
end

group :development do
  # Development tools
  gem 'web-console'
  gem 'listen', '~> 3.8'
  gem 'spring'
  gem 'spring-watcher-listen', '~> 2.1'
  
  # Email preview
  gem 'letter_opener', '~> 1.8'
  
  # Database tools
  gem 'annotate', '~> 3.2'
  
  # Performance profiling
  gem 'rack-mini-profiler', '~> 3.3'
  gem 'memory_profiler'
  gem 'stackprof'
end

group :test do
  # Testing utilities
  gem 'capybara', '~> 3.40'
  gem 'selenium-webdriver', '~> 4.16'
  gem 'webdrivers', '~> 5.2'  # Исправлено: совместимость с selenium-webdriver 4.16
  gem 'shoulda-matchers', '~> 6.1'
  gem 'database_cleaner-active_record', '~> 2.1'
  gem 'simplecov', '~> 0.22', require: false
  gem 'vcr', '~> 6.2'
  gem 'webmock', '~> 3.20'
end

group :production do
  # Production web server (optional, can use Puma)
  # gem 'unicorn', '~> 6.1'
  
  # Production monitoring
  # gem 'newrelic_rpm', '~> 9.7'
end
