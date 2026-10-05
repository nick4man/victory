# Конвейер новостей как контейнер. Расписание — supercronic (crontab.docker),
# а не crontab хоста: служба едет с кодом и тегом образа.
#
# Контекст сборки — каталог службы (compose: build.context). Соседние службы
# здесь не упоминаются намеренно (правило 3 services/README.md): скрипт зеркала
# на сайт подключает compose томом и переменной MIRROR_SCRIPT.
FROM python:3.12-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    TZ=Europe/Moscow \
    CONVEYOR_HOME=/opt/conveyor

# bash, jq, curl нужны скрипту зеркала; postgresql-client — pg_isready/psql
# для диагностики из контейнера (psycopg2-binary сам ничего не требует).
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends bash curl jq tzdata postgresql-client-15 && \
    rm -rf /var/lib/apt/lists/*

# supercronic — cron для контейнеров: пишет в stdout, пробрасывает окружение,
# не требует root. Версия и сумма пинуются; при обновлении сверить с
# https://github.com/aptible/supercronic/releases
ARG SUPERCRONIC_VERSION=v0.2.33
ARG SUPERCRONIC_SHA256
ADD https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-amd64 /usr/local/bin/supercronic
RUN if [ -n "$SUPERCRONIC_SHA256" ]; then echo "${SUPERCRONIC_SHA256}  /usr/local/bin/supercronic" | sha256sum -c -; fi && \
    chmod +x /usr/local/bin/supercronic

WORKDIR ${CONVEYOR_HOME}
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .
# Тесты — часть сборки: образ с красными тестами не существует.
RUN python3 -m unittest test_urgent_relevance test_classify_retry test_model_chains

RUN groupadd --gid 1000 app && useradd --uid 1000 --gid app --create-home app && \
    mkdir -p logs notifications published state mirror && chown -R app:app ${CONVEYOR_HOME}
USER app

CMD ["supercronic", "-passthrough-logs", "/opt/conveyor/crontab.docker"]
