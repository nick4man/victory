# chat-host → victory62 news ingest

Скрипт `post_news_to_victory.sh` шлёт сгенерированные на `chat`-сервере
новостные тексты (`urgent_*.txt` каждые 15 мин и `digest_*.txt` по
понедельникам) в Rails-вебхук `/webhooks/news_ingest`, который создаёт
запись в `articles` таблице. Появляется на /news через секунды.

## Архитектура

```
chat-server cron:
  urgent_trigger.py (every 15 min) →
    publishes urgent_YYYYMMDD_HHMMSS.txt + .meta.json
    → calls post_news_to_victory.sh
       → POST https://victory62.org/webhooks/news_ingest
          (Bearer NEWS_INGEST_TOKEN)
          → Article.create_or_update(external_id: 'urgent_…')
            → visible on /news

  weekly_digest_trigger.py (Monday 09:00 MSK) →
    same flow, with .meta.json prefix "digest_"
```

## Подключение (one-time)

### 1. На victory62 (этот репо)

`.env`:
```
NEWS_INGEST_TOKEN=<secure-random-32-chars>
```

Сгенерировать токен: `bin/rails secret | head -c 32`.

Перезапустить web: `docker compose up -d --force-recreate web`.

### 2. На chat-host

```bash
# Положить скрипт рядом с триггерами
scp services/chat-host-cron/post_news_to_victory.sh \
    chat:/opt/.openclaw/.openclaw/workspace-conveyor/IT/scripts/
ssh chat 'chmod +x /opt/.openclaw/.openclaw/workspace-conveyor/IT/scripts/post_news_to_victory.sh'

# Экспортировать токен в окружение, которое видит cron
ssh chat 'echo "export VICTORY_NEWS_TOKEN=<тот-же-токен>" >> ~/.bashrc'
ssh chat 'echo "export VICTORY_NEWS_URL=https://victory62.org/webhooks/news_ingest" >> ~/.bashrc'
```

### 3. Добавить вызов в триггерах

В конце `urgent_trigger.py` после успешной публикации:
```python
import subprocess, os
subprocess.run([
    "bash",
    "/opt/.openclaw/.openclaw/workspace-conveyor/IT/scripts/post_news_to_victory.sh",
    meta_path, text_path
], env={**os.environ, "VICTORY_NEWS_TOKEN": os.environ["VICTORY_NEWS_TOKEN"]},
   check=False)  # не падаем если victory62 down
```

То же самое в конце `weekly_digest_trigger.py`.

### 4. Проверка

```bash
# Manually trigger one
ssh chat 'VICTORY_NEWS_TOKEN=<token> bash /opt/.openclaw/.openclaw/workspace-conveyor/IT/scripts/post_news_to_victory.sh \
  /opt/.openclaw/.openclaw/workspace-conveyor/CREATIVE/published/urgent_LATEST.meta.json \
  /opt/.openclaw/.openclaw/workspace-conveyor/CREATIVE/published/urgent_LATEST.txt'

# Должно вернуть `[news_ingest] OK 200 created #N <url>`
# Открыть https://victory62.org/news — статья сверху
```

## Что делает скрипт

1. Читает `.meta.json` → `event_id`, `headline`, `hashtags`, optional `source_url`
2. Читает `.txt` → markdown body
3. Определяет `external_source` по префиксу файла (`urgent_*` → `chat_urgent`, `digest_*` → `chat_digest`)
4. POST на endpoint с bearer-токеном, JSON payload
5. Retry 3 раза с экспоненциальным backoff на 5xx/timeout

## Дедупликация

Скрипт шлёт `external_id` из meta. На стороне Rails `articles.external_id`
имеет unique-index — повторный POST просто обновит существующую запись
вместо создания дубля. Можно безопасно перезапускать.

## Модерация

Если LLM сгенерировал что-то неподобающее, открой
`https://victory62.org/admin/articles?token=<ADMIN_TOKEN>` → найди статью
→ «СКР» (скрыть). Она пропадает с /news, но остаётся в БД.

Кнопка «ВЕРН» возвращает обратно.

## Endpoint contract

`POST /webhooks/news_ingest`

Headers:
- `Authorization: Bearer <NEWS_INGEST_TOKEN>`
- `Content-Type: application/json`

Body:
```json
{
  "external_id": "urgent_20260511_141500",
  "external_source": "chat_urgent",
  "title": "Заголовок не менее 10 символов",
  "body_md": "Markdown тело не менее 10 символов",
  "category": "news",
  "schema_type": "NewsArticle",
  "hashtags": ["#тег1", "#тег2"],
  "source_url": "https://...",
  "image_url": "https://...",
  "published_at": "2026-05-11T14:15:00Z",
  "region": "ryazan"
}
```

Required: `title`, `body_md`. Остальное опционально (есть defaults).

Responses:
- `200` — `{ status: "ok", action: "created"|"updated", article_id, slug, url }`
- `401` — bad token
- `403` — `NEWS_INGEST_TOKEN` не настроен на сервере
- `422` — payload invalid (`{ error, detail }`)
