# frozen_string_literal: true

source 'https://rubygems.org'
git_source(:github) { |repo| "https://github.com/#{repo}.git" }

ruby '3.3.6'

# Core Rails — EOL Phase 1: 7.1.6 → 7.2.3.1 (CVE sweep 25.06.26: Ruby 3.2.2 →
# 3.3.6, закрывает Brakeman EOLRuby; Ruby 3.3 YJIT on по умолчанию).
# CVE sweep 08.08.26: 7.2.3.1 → 7.2.3.2 — CVE-2026-66066 (arbitrary file read +
# RCE в Active Storage variant processing; бьёт по нашему AVIF/webp pipeline).
gem 'rails', '~> 7.2.3', '>= 7.2.3.2'

# Database
gem 'pg', '~> 1.5'

# Server — CVE sweep 25.06.26: puma 6.4 имеет advisory, fix в 7.2.1+. Major
# bump 6→7 (boot-verified в этом PR). Конфиг config/puma.rb совместим.
gem 'puma', '~> 7.2', '>= 7.2.1'

# Security pins (transitive — EOL Phase 1, 04.06.26). Rails 7.2 подтянул rack 3.2.4
# / rack-session 2.1.1, в которых открыты CVE (rack: 6 advisories вкл. 2 High —
# host allowlist bypass CVE-2026-34827/34829; rack-session: secretless session
# forgery CVE-2026-39324). Явные floor-пины, пока transitive deps не догонят.
gem 'rack', '>= 3.2.6'
gem 'rack-session', '>= 2.1.2'
gem 'nokogiri', '>= 1.19.4' # XSLT/xmlC14N + new advisory (sweep 25.06.26)
gem 'net-imap', '>= 0.6.4.1' # command injection CVE-2026-42258 + CVE-2026-47240
gem 'concurrent-ruby', '>= 1.3.7' # CVE-2026-54904/54905/54906 (sweep 25.06.26)
# CVE sweep 08.08.26 — новые advisory против transitive deps (advisory-db догнала
# спустя ~6 недель после 25.06). Явные floor-пины до апстрим-догона.
gem 'websocket-driver', '>= 0.8.2' # High: DoS via malformed Host header + 3 more (GHSA)
gem 'loofah', '>= 2.25.2' # Medium: SVG href local-reference bypass (GHSA-9wjq-cp2p-hrgf)
gem 'rails-html-sanitizer', '>= 1.7.1' # XSS (GHSA-cj75-f6xr-r4g7)
gem 'crass', '>= 1.0.7' # 5× DoS advisories (транзитивно через loofah)
gem 'json', '>= 2.19.9' # CVE-2026-54696 heap buffer overflow when streaming to IO
gem 'msgpack', '>= 1.8.2' # CVE-2026-54522 use-after-free (DFVULN-839)

# Assets
gem 'sprockets-rails'
gem 'importmap-rails'
gem 'stimulus-rails'
gem 'turbo-rails'
gem 'jbuilder'

# CSS
gem 'tailwindcss-rails'

# Minimal auth
gem 'bcrypt', '~> 3.1', '>= 3.1.22'
gem 'jwt', '~> 2.10', '>= 2.10.3' # empty-key HMAC bypass CVE-2026-45363

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
gem 'sidekiq-cron', '~> 2.4' # 2.4+ закрывает XSS CVE-2025-67202

# Redis (Action Cable + Sidekiq + cache)
gem 'redis', '~> 5.0'

# Pagination
gem 'kaminari', '~> 1.2'

# Search
gem 'ransack', '~> 4.2'
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
gem 'neighbor', '~> 0.6'

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
gem 'faraday', '~> 2.9', '>= 2.14.3' # CVE-2026-33637 + CVE-2026-54297 (High, sweep 25.06.26)
gem 'faraday-retry', '~> 2.2'
gem 'stoplight', '~> 4.1'

# === Observability ===
# Sentry — error tracking + (optionally) performance monitoring. Gated на
# SENTRY_DSN env: если не задан → Sentry.init вообще не вызывается
# (sentry-ruby молчит, не ходит в Sentry servers). PII strip через
# before_send hook в config/initializers/sentry.rb.
gem 'sentry-ruby',     '~> 5.20', require: false
gem 'sentry-rails',    '~> 5.20', require: false
gem 'sentry-sidekiq',  '~> 5.20', require: false  # Capture Sidekiq job failures

# === Development tooling ===
# ruby-lsp нужен Serena MCP / IDE для navigation-by-symbol (find_definition,
# find_referencing_symbols, rename, etc) в Ruby-файлах проекта. `ruby-lsp-rails`
# — addon, добавляющий понимание Rails-конвенций (моделей, миграций, роутов,
# AR-связей). require: false — гем грузится только когда LSP-сервер
# поднимается, не нужен в runtime приложения.
group :development do
  gem 'ruby-lsp',       '~> 0.26', require: false
  gem 'ruby-lsp-rails', require: false

  # Linters & security scanners — run locally via `bundle exec` and in CI
  # (.github/workflows/lint.yml). All three are require: false so they
  # don't load into the app process.
  gem 'rubocop-rails',       '~> 2.25', require: false  # Rails-aware lint
  gem 'rubocop-rspec',       '~> 3.0',  require: false  # RSpec idioms
  gem 'rubocop-performance', '~> 1.21', require: false  # perf cops
  gem 'brakeman',            '~> 6.2',  require: false  # static security analysis
  gem 'bundler-audit',       '~> 0.9',  require: false  # CVE check against Gemfile.lock
end

# === Test framework ===
# RSpec + supporting gems. Required by spec/rails_helper.rb для запуска
# unit / request / model specs локально и в CI. Группа :development добавлена
# чтобы `bin/rails generate model …` рендерил RSpec stubs вместо minitest.
group :development, :test do
  gem 'rspec-rails',         '~> 7.0'    # RSpec + Rails integration
  gem 'factory_bot_rails',   '~> 6.4'    # fixtures replacement
  gem 'faker',               '~> 3.4'    # realistic test data (Ru locale в rails_helper)
  gem 'shoulda-matchers',    '~> 6.0'    # one-liner matchers (validate_presence_of, etc.)
  gem 'database_cleaner-active_record', '~> 2.2'  # DatabaseCleaner для request specs
  gem 'capybara',            '~> 3.40'   # browser-driver abstraction (system tests)
  gem 'webmock',             '~> 3.24'   # HTTP stubbing (stub_request в yandex_vision и др.)
end
