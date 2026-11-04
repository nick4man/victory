# Прод фиксирован на 3.4.10 (значение по умолчанию — сборка без --build-arg
# остаётся прежней). upgrade-сессия подменяет версию через RUBY_TARGET.
#
# Стадии:
#   base       — рантайм-пакеты, общие для всех;
#   build      — компиляторы, bundle install со всеми группами;
#   dev        — то, что было единственным образом до 1.0: все гемы, без
#                ассетов, без USER — под bind-mount и bin/rb
#                (docker-compose.ruby.yml, docker-compose.dev.yml: target: dev);
#   prod-build — гемы без development/test, assets:precompile;
#   prod       — код внутри, только runtime, user app. Стадия последняя,
#                поэтому `docker build .` без --target даёт её.
ARG RUBY_VERSION=3.4.10

FROM ruby:${RUBY_VERSION}-slim-bookworm AS base
ENV LANG=C.UTF-8 \
    TZ=Europe/Moscow \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_JOBS=4 \
    BUNDLE_RETRY=3
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
        libpq5 \
        libyaml-0-2 \
        libvips42 \
        # Мажорная версия пинуется намеренно: db/structure.sql грузится и
        # дампится через psql/pg_dump, а сервер у нас pg15. Метапакет
        # postgresql-client при бампе базового образа молча уедет на 16/17.
        postgresql-client-15 \
        curl \
        tzdata && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app

FROM base AS build
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
        build-essential \
        libpq-dev \
        libyaml-dev \
        git && \
    rm -rf /var/lib/apt/lists/*
COPY Gemfile Gemfile.lock ./
RUN bundle install

# dev: прежний единственный образ. Гемы development/test на месте, ассеты не
# собраны (в development их собирает tailwindcss-rails на лету), root — потому
# что код приезжает bind-mount'ом и compose подставляет user: UID:GID сам.
FROM build AS dev
COPY . .
RUN mkdir -p tmp/pids log storage
EXPOSE 3000
ENTRYPOINT ["/app/bin/docker-entrypoint"]
CMD ["bin/rails", "server", "-b", "0.0.0.0", "-p", "3000"]

# prod-build: убрать dev/test-гемы и собрать ассеты. SECRET_KEY_BASE_DUMMY —
# штатный способ Rails запустить precompile без настоящего секрета.
FROM build AS prod-build
RUN bundle config set --local without 'development test' && \
    bundle install && \
    bundle clean --force && \
    rm -rf "${BUNDLE_PATH}"/ruby/*/cache
COPY . .
RUN SECRET_KEY_BASE_DUMMY=1 RAILS_ENV=production bin/rails assets:precompile && \
    rm -rf node_modules tmp/cache

FROM base AS prod
ENV RAILS_ENV=production \
    BUNDLE_WITHOUT="development test" \
    BUNDLE_DEPLOYMENT=1
RUN groupadd --gid 1000 app && useradd --uid 1000 --gid app --create-home app
COPY --from=prod-build --chown=app:app /usr/local/bundle /usr/local/bundle
COPY --from=prod-build --chown=app:app /app /app
RUN mkdir -p tmp/pids tmp/sockets log storage && chown -R app:app tmp log storage
USER app
EXPOSE 3000
ENTRYPOINT ["/app/bin/docker-entrypoint"]
CMD ["bin/rails", "server", "-b", "0.0.0.0", "-p", "3000"]
