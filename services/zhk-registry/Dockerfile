# Реестр новостроек как контейнер: еженедельный обход по supercronic.
FROM python:3.12-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    TZ=Europe/Moscow

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends tzdata util-linux && \
    rm -rf /var/lib/apt/lists/*

# supercronic — та же версия и сумма, что у конвейера (один бинарь).
ARG SUPERCRONIC_VERSION=v0.2.33
ARG SUPERCRONIC_SHA256=feefa310da569c81b99e1027b86b27b51e6ee9ab647747b49099645120cfc671
ADD https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-amd64 /usr/local/bin/supercronic
RUN if [ -n "$SUPERCRONIC_SHA256" ]; then echo "${SUPERCRONIC_SHA256}  /usr/local/bin/supercronic" | sha256sum -c -; fi && \
    chmod 0755 /usr/local/bin/supercronic   # ADD по URL даёт 0600 — пользователю app нужен r+x

WORKDIR /opt/zhk-registry
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .
# Тесты — часть сборки. test_client и test_observation проверяют общий контракт
# по фикстуре spec/fixtures/zhk/ из Rails-дерева — в контексте сборки службы её
# нет, они гоняются из корня репозитория (см. SERVICE.md: tests).
RUN python3 -m unittest tests.test_erz tests.test_edinstvo tests.test_run -v

RUN groupadd --gid 1000 app && useradd --uid 1000 --gid app --create-home app
USER app

CMD ["supercronic", "-passthrough-logs", "/opt/zhk-registry/crontab.docker"]
