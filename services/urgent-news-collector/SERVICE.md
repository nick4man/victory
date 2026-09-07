---
service: urgent-news-collector
owner: victory
kind: python-cron
entrypoint: urgent_collector.py
tests: cd services/urgent-news-collector && python3 -m unittest discover
deploy: cron на openclaw-машине, см. crontab.example
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

## Репозиторий openclaw и каталог openclaw — разные вещи

Их смешение и размыло владение, поэтому проговариваем отдельно:

- **репозиторий** `github.com/nick4man/openclaw` — архив. Напрямую не
  правится больше никогда. Из него мы постепенно разбираем и доводим до ума
  код, который писался для агентства;
- **каталог** `/opt/.openclaw/.openclaw/workspace-conveyor/IT/scripts` на
  диске — боевой: оттуда крон запускает конвейер. Это цель **деплоя**, а не
  источник правды.

Отсюда правило: `./sync-check.sh` больше не «сверка двух копий», а выкладка.
Забирать что-либо оттуда нечего — режима `--pull-vendored` не существует.

## Восемь чужих потребителей

`bank_rates_trigger.py`, `weekly_digest_trigger.py`, `backfill_embeddings.py`,
`weekly_infra_check.py`, `test_digest_resilience.py` и соседи лежат в архиве и
импортируют оба общих модуля. После выкладки они работают с нашей копией.
Довести их до ума и перенести сюда — часть общего разбора архива, к владению
модулями отношения не имеет.

## Граница

Служба не импортирует ни другие каталоги `services/`, ни Rails-код. Обмен с
Rails — только через вебхук, контракт которого (`app/controllers/webhooks/`)
намеренно выкачен в worktree этой службы.
