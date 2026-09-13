---
service: urgent-news-collector
owner: victory
kind: python-cron
entrypoint: urgent_collector.py
tests: cd services/urgent-news-collector && python3 -m unittest discover
deploy: ./deploy.sh в /opt/victory-conveyor, крон оттуда — см. crontab.example
depends_on: none
ported_from: openclaw (архив)
port_status: done
repatriate_by: —
---

# urgent-news-collector

Конвейер срочных новостей: сбор, оценка релевантности, отправка в Rails через
вебхук `/webhooks/news_ingest`.

## Владение

**Victory владеет всеми файлами службы, без исключений** — включая
`pipeline_utils.py` и `content_db_utils.py`, которые до 07.09.26 считались
вендором из openclaw. Прежний запрет «эти два файла здесь не править» снят.

## openclaw — архив целиком (11.09.26)

07.09.26 разделили две вещи: **репозиторий** `github.com/nick4man/openclaw` —
архив, а **каталог** `/opt/.openclaw/.openclaw/workspace-conveyor/IT/scripts` на
диске — боевой, цель выкладки. Разделение сняло путаницу с владением, но
оставило прод внутри архива.

11.09.26 архивом объявлен и каталог: `/opt/.openclaw/.openclaw/**` — только
чтение. Боевой каталог теперь `/opt/victory-conveyor`, наполняется `deploy.sh`
(`git fetch` + `git archive` из `origin/main`). `sync-check.sh` отключён вместе с режимом `--deploy`:
выкладывать в архив больше некуда. Запрет продублирован в
`.claude/settings.json` (`permissions.deny`).

Боевой каталог держит то, чего нет в git и что деплой не трогает: `.env`
(секреты), `logs/`, `notifications/`, `published/`, `state/`, `.venv/`.

## Зеркало на сайт — чужое

`MIRROR_SCRIPT` указывает на `post_news_to_victory.sh`, который принадлежит
службе chat-host-cron и выкладывается её собственным деплоем. `deploy.sh` его
намеренно **не тянет** — только проверяет, что исполняемый файл лежит по пути,
и предупреждает, если нет. Связь двух служб — контракт «файл по пути», а не
импорт; это и проверяет `bin/services-check`.

## Соседи по архиву

`bank_rates_trigger.py` и `weekly_digest_trigger.py` **переехали сюда**
11.09.26: оба публикуют в victory (`posts_queue`, вебхук `news_ingest`) и делят
с коллектором `pipeline_utils.py` / `content_db_utils.py` — врозь вышли бы две
расходящиеся копии общих модулей.

В архиве остались `backfill_embeddings.py`, `weekly_infra_check.py`,
`ingest_macro_economics.py`, `ingest_posts_queue.py`, `gemini_embedding_writer.py`,
`auto_assembly_trigger.py`, `test_digest_resilience.py`. Они в victory не
публикуют, их крон-строки всё ещё читают архив — чтение разрешено. Довести их
до ума — часть общего разбора архива.

## Граница

Служба не импортирует ни другие каталоги `services/`, ни Rails-код. Обмен с
Rails — только через вебхук, контракт которого (`app/controllers/webhooks/`)
намеренно выкачен в worktree этой службы.
