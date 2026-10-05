# publisher-bot: последнее звено конвейера новостей — читает posts_queue,
# шлёт карточки согласования в Telegram, публикует в канал по слотам.
# Долгоживущий процесс (python main.py), расписание внутри (APScheduler).
FROM python:3.12-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    TZ=Europe/Moscow

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends tzdata && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY publisher_bot/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY publisher_bot/ .

RUN groupadd --gid 1000 app && useradd --uid 1000 --gid app --create-home app && \
    mkdir -p media posts_queue && chown -R app:app /app
USER app

CMD ["python", "main.py"]
