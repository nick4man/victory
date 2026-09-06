# Владение кодом и вендоринг

Решение 06.09.26: **владелец конвейера — victory**. Этот каталог — источник правды
для самого коллектора. Но два файла здесь **вендорятся** из соседнего репозитория,
и править их в этом дереве нельзя.

## Кто чем владеет

| Файл | Владелец | Направление синка |
|---|---|---|
| `urgent_collector.py`, `urgent_trigger.py`, `urgent_relevance.py` | **victory** | victory → боевой каталог |
| `test_urgent_relevance.py`, `backtest_urgent_relevance.py` | **victory** | victory → боевой каталог |
| `.env.example`, `crontab.example`, `requirements.txt`, `README.md`, `CLAUDE.md`, `VENDOR.md` | **victory** | не деплоятся |
| `pipeline_utils.py` | **openclaw** — вендор | openclaw → victory |
| `content_db_utils.py` | **openclaw** — вендор | openclaw → victory |

## Почему два файла не наши

`pipeline_utils.py` и `content_db_utils.py` — общая инфраструктура конвейера. Кроме нашего
коллектора их импортируют ещё восемь скриптов, которые живут только в openclaw:
`bank_rates_trigger.py`, `weekly_digest_trigger.py`, `backfill_embeddings.py`,
`weekly_infra_check.py`, `test_digest_resilience.py` и соседи. Забрать эти файлы себе victory
не может — пришлось бы забирать и всех потребителей.

🚨 Правка `pipeline_utils.py` / `content_db_utils.py` в этом дереве будет затёрта следующим
синком, а до тех пор тихо разойдётся с боевой копией. Менять их — в openclaw, потом
`./sync-check.sh --pull-vendored`.

Отсюда главный риск: правка общих модулей ради `bank_rates_trigger` меняет поведение нашего
коллектора, и ни один тест victory этого не заметит — `MAIN_MODEL_CHAIN`, `PAID_MODELS` и
пороги дедупа живут именно в `pipeline_utils.py`. Гоняй `./sync-check.sh` перед работой и
перед PR.

## Upstream

- Репозиторий: `github.com/nick4man/openclaw`, рабочая копия — `/opt/.openclaw/.openclaw`
- Каталог: `workspace-conveyor/IT/scripts/` — он же **боевой**: оттуда крон запускает конвейер
- Импортировано: 06.09.26 (коммит `838688a`); на тот момент все шесть общих файлов
  совпадали с боевыми байт-в-байт

История конвейера до импорта лежит в openclaw (`a9ebd09`, `de3f2a5`, `46681ae`) — в victory
она не переносилась, `git log` здесь начинается с одного коммита.

## Открытый вопрос

Файлы коллектора сейчас **tracked в обоих репозиториях**. Пока это так, «владеет victory» —
договорённость, а не механика: ничто не мешает править боевую копию в openclaw напрямую.
Закрыть можно, сняв их с учёта в openclaw (`git rm --cached` + `.gitignore`) и доставляя
туда через `./sync-check.sh --push-owned`. Решение не принято — сделано вне этого каталога.
