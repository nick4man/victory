# Реестр новостроек как контейнер: еженедельный обход по supercronic.
FROM python:3.12-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    TZ=Europe/Moscow

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends tzdata && \
    rm -rf /var/lib/apt/lists/*

# supercronic — та же версия и сумма, что у конвейера (один бинарь).
ARG SUPERCRONIC_VERSION=v0.2.33
ARG SUPERCRONIC_SHA256
ADD https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-amd64 /usr/local/bin/supercronic
RUN if [ -n "$SUPERCRONIC_SHA256" ]; then echo "${SUPERCRONIC_SHA256}  /usr/local/bin/supercronic" | sha256sum -c -; fi && \
    chmod +x /usr/local/bin/supercronic

WORKDIR /opt/zhk-registry
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .
RUN python3 -m unittest discover -v

RUN groupadd --gid 1000 app && useradd --uid 1000 --gid app --create-home app
USER app

CMD ["supercronic", "-passthrough-logs", "/opt/zhk-registry/crontab.docker"]
