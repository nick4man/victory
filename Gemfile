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
gem 'tailwindcss-rails'

# Minimal auth
gem 'bcrypt', '~> 3.1.7'
gem 'jwt', '~> 2.8'

# Authorization
gem 'pundit', '~> 2.3'

# Authentication (Devise)
gem 'devise', '~> 4.9'

# State machine (used by Inquiry)
gem 'aasm', '~> 5.5'

# PDF generation (used by PdfGeneratorService and CrmReports::* templates)
gem 'prawn', '~> 2.5'
gem 'prawn-table', '~> 0.2'

# Background jobs
gem 'sidekiq', '~> 7.2'
gem 'sidekiq-cron', '~> 1.12'

# Redis (Action Cable + Sidekiq + cache)
gem 'redis', '~> 5.0'

# Pagination
gem 'kaminari', '~> 1.2'

# Search
gem 'ransack', '~> 4.1'
gem 'pg_search', '~> 2.3'

# URL slugs
gem 'friendly_id', '~> 5.5'

# Active Storage image variants (webp/jpeg, resize) — required by libvips. Uses
# the ruby-vips FFI bindings to libvips42 installed in the container.
gem 'image_processing', '~> 1.13'

# Markdown rendering for Article body (blog + market reports).
gem 'redcarpet', '~> 3.6'

# Geocoding
gem 'geocoder', '~> 1.8'

# Vector search (pgvector ActiveRecord helpers — used by PropertyEmbedding for
# semantic property search via cosine distance on Google gemini-embedding-001 vectors).
# PostGIS is enabled at the DB level only; we use raw SQL for ST_DWithin to avoid
# swapping the AR adapter from `postgresql` to `postgis`.
gem 'neighbor', '~> 0.5'

# API
gem 'rack-cors', '~> 2.0'

# SEO meta tags (used by PagesController#set_meta_tags)
gem 'meta-tags', '~> 2.21'

# Performance
gem 'bootsnap', require: false

# QR codes for PDF reports (Telegram channel + site URL on report covers).
# Pure Ruby; renders to PNG via mini_magick or to SVG natively (we use SVG
# for Prawn embedding — small + crisp at any DPI).
gem 'rqrcode', '~> 2.2'

# HTTP client for audit-engine sidecar (Investment Audit) and Brave Search
# (Express hybrid comparable fallback). Faraday-retry handles transient
# 429/503 from the engine; Stoplight wraps calls in a circuit breaker so a
# down sidecar degrades gracefully instead of stalling Puma threads.
gem 'faraday', '~> 2.9'
gem 'faraday-retry', '~> 2.2'
gem 'stoplight', '~> 4.1'

# === Development tooling ===
# ruby-lsp нужен Serena MCP / IDE для navigation-by-symbol (find_definition,
# find_referencing_symbols, rename, etc) в Ruby-файлах проекта. `ruby-lsp-rails`
# — addon, добавляющий понимание Rails-конвенций (моделей, миграций, роутов,
# AR-связей). require: false — гем грузится только когда LSP-сервер
# поднимается, не нужен в runtime приложения.
group :development do
  gem 'ruby-lsp',       '~> 0.26', require: false
  gem 'ruby-lsp-rails', require: false
end
