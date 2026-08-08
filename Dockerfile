# Прод фиксирован на 3.3.6 (значение по умолчанию — сборка без --build-arg
# остаётся байт-в-байт прежней). upgrade-сессия подменяет версию через
# docker-compose.upgrade.yml (RUBY_TARGET), чтобы щупать 3.4/3.5 не трогая прод.
ARG RUBY_VERSION=3.3.6
FROM ruby:${RUBY_VERSION}-slim-bookworm

ENV LANG=C.UTF-8 \
    TZ=Europe/Moscow \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_JOBS=4 \
    BUNDLE_RETRY=3

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
        build-essential \
        libpq-dev \
        libyaml-dev \
        libvips42 \
        postgresql-client \
        git \
        curl \
        tzdata && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle install

COPY . .

RUN mkdir -p tmp/pids log storage

EXPOSE 3000

ENTRYPOINT ["/app/bin/docker-entrypoint"]
CMD ["bin/rails", "server", "-b", "0.0.0.0", "-p", "3000"]
