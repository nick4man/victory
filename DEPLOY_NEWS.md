# Deploy: News ingest from chat-host

Полная инструкция подключения. Все шаги для копирования-вставки.

## Шаг 1 — токен сгенерирован

В `.env` уже добавлено:
```
NEWS_INGEST_TOKEN=c6115f70f8a43eea21c12038dcc485086969f10ab8e88647
```

Web-контейнер перезапущен, токен загружен. Проверка из любого места:
```bash
curl -sS -o /dev/null -w "%{http_code}\n" \
  -X POST \
  -H "Authorization: Bearer c6115f70f8a43eea21c12038dcc485086969f10ab8e88647" \
  -H "Content-Type: application/json" \
  -d '{"title":"test test test test test test","body_md":"body body body body body"}' \
  https://victory62.org/webhooks/news_ingest
# должно вернуть 200
```

---

## Шаг 2 — копируем скрипт на chat-host

С локальной машины (где есть SSH-доступ к chat):

```bash
scp /home/q/victory/services/chat-host-cron/post_news_to_victory.sh \
    chat:/opt/.openclaw/.openclaw/workspace-conveyor/IT/scripts/post_news_to_victory.sh
ssh chat 'chmod +x /opt/.openclaw/.openclaw/workspace-conveyor/IT/scripts/post_news_to_victory.sh'
```

---

## Шаг 3 — экспорт токена в окружение

```bash
ssh chat 'cat >> ~/.bashrc <<EOF

# victory62 news webhook
export VICTORY_NEWS_TOKEN=c6115f70f8a43eea21c12038dcc485086969f10ab8e88647
export VICTORY_NEWS_URL=https://victory62.org/webhooks/news_ingest
EOF'
```

Для cron нужно ENV прокинуть **в crontab напрямую** (cron не читает .bashrc):
```bash
ssh chat 'crontab -l > /tmp/crontab.bak && \
  (echo "VICTORY_NEWS_TOKEN=c6115f70f8a43eea21c12038dcc485086969f10ab8e88647"; \
   echo "VICTORY_NEWS_URL=https://victory62.org/webhooks/news_ingest"; \
   crontab -l) | crontab -'
# проверить:
ssh chat 'crontab -l | head -3'
```

---

## Шаг 4 — добавляем вызов в триггеры

В **самый конец** обоих файлов на chat-host:

`/opt/.openclaw/.openclaw/workspace-conveyor/IT/scripts/urgent_trigger.py`
`/opt/.openclaw/.openclaw/workspace-conveyor/IT/scripts/weekly_digest_trigger.py`

добавить (после успешной публикации):

```python
# === victory62 web-mirror ===
try:
    import subprocess, os
    if meta_path and text_path:  # имена переменных могут отличаться в твоём скрипте —
                                  # это пути к .meta.json и .txt которые только что записаны
        subprocess.run(
            ["/opt/.openclaw/.openclaw/workspace-conveyor/IT/scripts/post_news_to_victory.sh",
             str(meta_path), str(text_path)],
            env={**os.environ},
            check=False,           # не падаем если victory62 down
            timeout=30
        )
except Exception as e:
    import logging
    logging.warning(f"[victory62-mirror] failed: {e}")
```

**Где именно вставить:** найди в каждом скрипте место, где переменные `meta_path` / `text_path` (или как у тебя названы пути к свежим файлам) уже определены, и вставь блок сразу после успешной публикации в Telegram. Подразумеваем, что путь к .txt-файлу и .meta.json известны.

Если переменные называются иначе — поправь имена в `str(meta_path)` и `str(text_path)`.

---

## Шаг 5 — ручной тест после подключения

```bash
# Найди последний urgent_*.txt + .meta.json
ssh chat 'ls -t /opt/.openclaw/.openclaw/workspace-conveyor/CREATIVE/published/urgent_*.txt | head -1'

# Запусти скрипт вручную (подставь актуальные имена)
ssh chat 'export VICTORY_NEWS_TOKEN=c6115f70f8a43eea21c12038dcc485086969f10ab8e88647 && \
  bash /opt/.openclaw/.openclaw/workspace-conveyor/IT/scripts/post_news_to_victory.sh \
    /opt/.openclaw/.openclaw/workspace-conveyor/CREATIVE/published/urgent_LATEST.meta.json \
    /opt/.openclaw/.openclaw/workspace-conveyor/CREATIVE/published/urgent_LATEST.txt'
# Должно вернуть `[news_ingest] OK 200 created #N <url>`
```

Затем открой https://victory62.org/news — статья сверху.

---

## Шаг 6 — открыть админку и удалить тестовые статьи

```
https://victory62.org/admin/articles?token=<значение ADMIN_TOKEN из .env>
```

ADMIN_TOKEN в .env уже: `admin-dev-token-rotate-in-prod`.

**ВАЖНО для prod:** замени токен на безопасный:
```bash
NEW_TOKEN=$(docker compose exec -T web bin/rails secret | tail -1 | tr -d '\r' | head -c 32)
sed -i "s|^ADMIN_TOKEN=.*|ADMIN_TOKEN=${NEW_TOKEN}|" /home/q/victory/.env
docker compose up -d --force-recreate web
echo "New ADMIN_TOKEN: $NEW_TOKEN"
```

---

## Что уже сделано

- [x] CLAUDE.md: статус → PRODUCTION
- [x] NEWS_INGEST_TOKEN сгенерирован и записан в .env (длина 48)
- [x] Web-контейнер перезапущен с новым токеном
- [x] services/chat-host-cron/post_news_to_victory.sh готов к копированию
- [x] services/chat-host-cron/README.md инструкция

## Что нужно сделать вам (классifier блокирует мне доступ на запись chat-host)

- [ ] Шаг 2: scp скрипта на chat-host
- [ ] Шаг 3: экспорт VICTORY_NEWS_TOKEN
- [ ] Шаг 4: вставить subprocess в `urgent_trigger.py` + `weekly_digest_trigger.py`
- [ ] Шаг 5: ручной smoke-test
- [ ] Шаг 6: открыть admin и (важно) сменить ADMIN_TOKEN на prod-уровне
