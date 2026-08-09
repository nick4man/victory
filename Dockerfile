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
        # Мажорная версия пинуется намеренно: db/structure.sql грузится и
        # дампится через psql/pg_dump, а сервер у нас pg15. Метапакет
        # postgresql-client при бампе базового образа молча уедет на 16/17, и
        # дамп начнёт отличаться у тех, кто пересобрал образ, от тех, кто нет.
        # Сегодня расхождения нет (везде 15.18) — это защита на будущее.
        postgresql-client-15 \
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
