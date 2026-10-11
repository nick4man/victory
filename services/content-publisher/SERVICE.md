---
service: content-publisher
owner: victory
kind: python-service
entrypoint: publisher_bot/main.py
tests: не заведены — перенесено 05.10.26 как есть; покрытие — часть следующего круга
deploy: compose-служба publisher (профиль conveyor) в корневом docker-compose.yml
depends_on: none
ported_from: chat:/opt/.openclaw/.openclaw/workspace/agents/content-publisher (архив openclaw)
port_status: done
repatriate_by: —
---

# content-publisher

Публикатор Telegram-канала @rznvictory — последнее звено конвейера новостей.
Читает `posts_queue`, шлёт карточки согласования (Оксана / Д'Артаньян / главред),
публикует по слотам `PUBLISH_SLOTS`, пишет историю правок в `content_revisions`.

Контракт с коллектором — только через таблицу `posts_queue` в общей базе
`news-db`; кода друг друга службы не знают.

## Что изменено при переносе (05.10.26)

- Убраны дефолтные `DATABASE_URL` с паролем в `config.py` и `ingest_post.py` —
  переменная обязательна.
- Не перенесены: `AGENTS.md`, `SOUL.md`, `config/` (persona и конфиг моделей
  openclaw, в `models.json` лежал API-ключ), `run_ingest.sh` и `start.sh`
  (пароль в открытом виде, запуск через `docker-compose` из архива).
- `db/migrations/001_posts_queue.sql` — исходная DDL; боевую схему `news-db`
  получает из единого дампа обеих таблиц (каталог `schema/` у коллектора).

## Запуск

```
docker compose --profile conveyor up -d publisher
```

`.env.publisher` — по `.env.example`.
