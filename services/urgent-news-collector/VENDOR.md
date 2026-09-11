# Владение кодом

Решение 11.09.26: **openclaw — архив**. `/opt/.openclaw/.openclaw/**` доступен
только на чтение, писать туда нельзя, вендоринг прекращён. Весь боевой код
конвейера принадлежит victory и живёт здесь.

Это отменяет прежнюю схему (06.09.26), где `pipeline_utils.py` и
`content_db_utils.py` вендорились из openclaw, а боевой копией был каталог
`workspace-conveyor/IT/scripts` внутри архива.

## Кто чем владеет

| Файл | Владелец |
|---|---|
| `urgent_collector.py`, `urgent_trigger.py`, `urgent_relevance.py` | victory |
| `weekly_digest_trigger.py`, `bank_rates_trigger.py` | victory — забраны из архива 11.09.26 |
| `pipeline_utils.py`, `content_db_utils.py` | victory — вендоринг прекращён 11.09.26 |
| `test_urgent_relevance.py`, `backtest_urgent_relevance.py` | victory |
| `deploy.sh`, `.env.example`, `crontab.example`, `requirements.txt`, `README.md`, `CLAUDE.md` | victory |
| `post_news_to_victory.sh` (зеркало) | victory — лежит в `services/chat-host-cron/`, деплоится сюда же |

Никаких «чужих» файлов в каталоге больше нет. Правь любой — источник правды один.

## Где боевой код

```
исходник   services/urgent-news-collector/   ← этот каталог, git
боевой     /opt/victory-conveyor/            ← крон запускает отсюда
```

Выкатка — только `./deploy.sh` (внутри `git archive` из `main`). Прямых правок
в боевом каталоге не делаем: следующий деплой их затрёт молча.

```bash
./deploy.sh            # выкатить main
./deploy.sh <ветка>    # выкатить конкретную ревизию
```

Боевой каталог держит то, чего нет в git и что деплой не трогает:
`.env` (секреты), `logs/`, `notifications/`, `published/`, `.venv/`.

## Что осталось в архиве

Соседи по бывшему `workspace-conveyor/IT/scripts`, которые в victory не публикуют
и потому не переезжали: `auto_assembly_trigger.py`, `weekly_infra_check.py`,
`backfill_embeddings.py`, `ingest_macro_economics.py`, `ingest_posts_queue.py`,
`gemini_embedding_writer.py`, `test_digest_resilience.py`. Их крон-строки всё ещё
бьют в архив — это чтение, оно разрешено, но владельца у кода там больше нет.

Единственная связь нашего кода с архивом — `OPENCLAW_JSON_PATH`
(`pipeline_utils.py`): читает `openclaw.json`, если `OMNIROUTE_API_KEY` не задан
в `.env`. В проде задан, так что фолбэк не срабатывает.

## Синк запрещён

`sync-check.sh` отключён 11.09.26 — файл на месте, но отказывается запускаться
и объясняет почему. Запрет продублирован в `.claude/settings.json`
(`permissions.deny`), туда же добавлен запрет на запись в архив.

## История

Конвейер импортирован в victory 06.09.26 (коммит `838688a`) из
`github.com/nick4man/openclaw`. История до импорта осталась там же
(`a9ebd09`, `de3f2a5`, `46681ae`) и в victory не переносилась.
