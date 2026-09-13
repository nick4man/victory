# CLAUDE.md — urgent-news-collector

Python-конвейер новостей внутри Rails-репозитория. Всё здесь устроено иначе, чем в
остальном `victory`. Корневой `CLAUDE.md` и skill `victory-rails-conventions` сюда
**не применяются** — из трёх жёстких правил репозитория едет только одно: даты `dd.MM.yy`.

## Чем отличается от Rails-части

| | Здесь |
|---|---|
| Язык, зависимости | Python + `pip` + `venv`, пины в `requirements.txt`. Не bundler, не `mise.toml` (python там не объявлен) |
| Стиль | двойные кавычки, type hints, `from __future__ import annotations` — противоположность `.rubocop.yml` |
| Тесты | stdlib `unittest`. Ни pytest, ни rspec |
| Расписание | системный crontab (`crontab.example`). **Не** `whenever` и не `config/schedule.rb` |

🚨 Не добавляй задачи этого сервиса в `config/schedule.rb`: `whenever --update-crontab`
затрёт боевое расписание, написанное руками.

## Запуск тестов

```bash
python3 -m unittest test_urgent_relevance -v   # 26 тестов, без сети и БД
```

Только **из каталога сервиса**: импорты плоские (`from urgent_relevance import ...`),
модули находят друг друга как соседи. Из корня репозитория не сработает.

`.venv` в репозитории нет — тесты гоняются системным `python3`, потому что
`urgent_relevance` не тянет ничего кроме `re`. Виртуалка с `requirements.txt` нужна только
для самого конвейера (`urgent_collector` / `urgent_trigger`: feedparser, psycopg2, requests).

## Две чужие БД

- `NEWS_DB_*` — порт **5433**, pgvector, таблица `urgent_events`.
- `DB_*` — прод, `posts_queue` и `system_flags`.

Если `NEWS_DB_*` пусты, код падает обратно на `DB_*`. Ни одна из этих БД **не описана
миграциями в `db/migrate`** и не совпадает с `docker-compose.yml`. Увидев `urgent_events`,
не считай её забытой таблицей и не генерируй Rails-миграцию. В прод-БД колонки embedding
нет вовсе — там alpine postgres без pgvector.

## Где боевой код

```
исходник   services/urgent-news-collector/   ← этот каталог
боевой     /opt/victory-conveyor/            ← крон запускает отсюда
```

Выкатка — только `./deploy.sh` (`git archive` из `main`). Правки прямо в боевом
каталоге затрёт следующий деплой.

История в два шага. 07.09.26 (#40) архивом объявили **репозиторий** openclaw, а
каталог `workspace-conveyor/IT/scripts` оставили боевым — целью выкладки.
11.09.26 архивом объявлен и **каталог**: `/opt/.openclaw/.openclaw/**` только на
чтение, писать нельзя, `sync-check.sh` отключён. Пути наружу сняты с кода и
собраны под `CONVEYOR_HOME` (env, дефолт `/opt/victory-conveyor`): `logs/`,
`notifications/`, `published/`, зеркало.

⚠️ `CONVEYOR_HOME` читается уже после загрузки `.env`, а `MIRROR_SCRIPT` и
`NOTIFICATIONS_DIR` в `pipeline_utils.py` — функции, а не константы. Если
вернёшь их на уровень модуля, значение из `.env` снова начнёт молча
игнорироваться: вызывающие скрипты грузят `.env` уже после `import`.

Зеркалирование на сайт идёт **внешним** скриптом по `MIRROR_SCRIPT` — он
принадлежит службе chat-host-cron и в боевом каталоге должен лежать рядом.
Связь с ним — контракт «исполняемый файл по пути», а не импорт: службы друг о
друге не знают, это проверяет `bin/services-check`. Без него зеркало молча
возвращает `None`, и посты уходят с fallback-URL.

## Владение: всё здесь наше

Чужих файлов в каталоге нет — ни одного. `pipeline_utils.py` и
`content_db_utils.py` перестали быть вендором 07.09.26, полная таблица и
границы — в `SERVICE.md`, история решения — в `VENDOR.md`.

С 11.09.26 здесь живут ещё два боевых скрипта, забранных из архива:
`weekly_digest_trigger.py` (еженедельный дайджест) и `bank_rates_trigger.py`
(ставки банков). Оба импортируют те же `pipeline_utils` / `content_db_utils`,
поэтому и переехали вместе — врозь вышли бы две расходящиеся копии общих
модулей.

## Что нельзя трогать «на глаз»

- **Порог дедупа 0.92** и якоря только по `published_to_tg = TRUE`. Порог 0.85 резал валидные
  новости: на коротких русских официальных заголовках baseline сам по себе ~0.85+. Без привязки
  к `published_to_tg` зарезанные события становились якорями для следующих — это стоило 4 дней
  тишины и ~31 потерянного события.
- **`URGENT_ELIGIBLE_TYPES` — ровно пять типов.** `MACRO_ECONOMICS` и `FX_RATE` исключены по
  замеру: 84 срочные публикации за 30 дней против 14.
- **Порядок `MAIN_MODEL_CHAIN`** (`pipeline_utils.py:292`): сначала бесплатные, платный
  `anthropic/claude-sonnet-4` последний и помечен в `PAID_MODELS`. Подняв его выше, ты включишь
  платную модель на кроне каждые 15 минут, молча.
- **`URGENT_COLLECTOR_MODEL` / `URGENT_TRIGGER_MODEL` / `OMNIROUTE_MODEL` в `.env`.**
  Это не «добавить модель», а схлопнуть всю цепочку в один маршрут без фолбэка
  (`urgent_collector.py:303`). 07.09.26 туда прописали `cc/claude-sonnet-4-5`, у
  которого в omniroute нет кредов — конвейер встал на 4 дня, 1950 новостей ушли
  в `NOISE` без классификации, и переклассифицировать их уже нельзя
  (`already_seen` режет по `source_url`).

## Контракт с Rails

Единственная точка связи — `app/controllers/webhooks/news_ingest_controller.rb`. Меняя вебхук
со стороны Rails, проверяй Python-конец: он в другом каталоге, на другом языке и не покрыт
ни одним rspec.

## Секреты

`.env` закрыт локальным `.gitignore` и не коммитился ни разу. Держи так: в репозиторий едут
только `.env.example` и `crontab.example`.
