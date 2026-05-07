# syntax=docker/dockerfile:1
# ──────────────────────────────────────────────────────────────────────────────
# АН "Виктори" — multi-stage production Dockerfile
#
# Stages:
#   base   – shared Ruby runtime image
#   build  – compile gems (native extensions) + precompile assets
#   final  – minimal runtime image (no build tools)
#
# Build:
#   docker build -t victory:latest .
#
# ARM note: if building on Apple Silicon or aarch64 servers, add the linux
# arm64 platform to Gemfile.lock first:
#   bundle lock --add-platform aarch64-linux
# ──────────────────────────────────────────────────────────────────────────────

ARG RUBY_VERSION=3.2.2
ARG BUNDLER_VERSION=2.7.2

# ── Stage: base ───────────────────────────────────────────────────────────────
FROM ruby:${RUBY_VERSION}-slim AS base

ARG BUNDLER_VERSION

WORKDIR /app

# Locale / timezone
ENV LANG=C.UTF-8 \
    TZ=Europe/Moscow \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT="development:test" \
    RAILS_LOG_TO_STDOUT=true \
    RAILS_SERVE_STATIC_FILES=true

RUN gem install bundler -v "${BUNDLER_VERSION}" --no-document

# ── Stage: build ──────────────────────────────────────────────────────────────
FROM base AS build

# Build-time system deps:
#   build-essential  – native gem extensions (sassc, etc.)
#   libpq-dev        – pg gem
#   git              – gems sourced from git
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential \
      libpq-dev \
      git \
      curl && \
    rm -rf /var/lib/apt/lists/*

# Install gems (cached layer — only re-runs when Gemfile changes)
COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs "$(nproc)" --retry 3 && \
    # Strip gem caches to shrink image
    rm -rf "${BUNDLE_PATH}/ruby/*/cache" \
           "${BUNDLE_PATH}/ruby/*/bundler/gems/*/.git"

# Copy application source
COPY . .

# Precompile Tailwind CSS + Sprockets assets.
# SECRET_KEY_BASE_DUMMY prevents the key-not-set error during precompile.
# tailwindcss-ruby gem bundles the platform binary (no download needed).
RUN SECRET_KEY_BASE_DUMMY=1 \
    RAILS_ENV=production \
    bundle exec rails tailwindcss:build assets:precompile

# ── Stage: final ──────────────────────────────────────────────────────────────
FROM base AS final

# Runtime system deps only (no compilers):
#   libpq5    – PostgreSQL client library for pg gem
#   libvips42 – Active Storage image processing (optional but cheap)
#   curl      – health-check probe
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      libpq5 \
      libvips42 \
      curl && \
    rm -rf /var/lib/apt/lists/*

# Non-root user for security
RUN useradd --create-home --uid 1001 --shell /bin/bash rails

# Copy installed gems from build stage
COPY --chown=rails:rails --from=build /usr/local/bundle /usr/local/bundle

# Copy application (with precompiled assets)
COPY --chown=rails:rails --from=build /app /app

# Ensure runtime directories exist and are writable by the rails user
RUN mkdir -p tmp/pids tmp/sockets log storage && \
    chown -R rails:rails tmp log storage

USER rails

EXPOSE 5000

ENTRYPOINT ["/app/bin/docker-entrypoint"]
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
