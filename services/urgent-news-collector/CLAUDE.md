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

## Сервис НЕ переносим

Жёстко зашиты пути наружу, в `/opt/.openclaw/.openclaw/workspace-conveyor`:
`WORKSPACE` (`urgent_trigger.py:12`), `MIRROR_SCRIPT` и `NOTIFICATIONS_DIR`
(`pipeline_utils.py:43,153`). Ни один не вынесен в `.env.example`.

Зеркалирование на сайт идёт **внешним** скриптом по `MIRROR_SCRIPT`. Рядом лежит копия
`services/chat-host-cron/post_news_to_victory.sh` — она **не используется**; не «чини»
дублирование переключением на неё, боевой скрипт другой. Без `workspace-conveyor` зеркало
молча возвращает `None`, и посты уходят с fallback-URL.

Боевая копия конвейера исполняется кроном из `workspace-conveyor/IT/scripts/`, а не отсюда.
Репозиторий — исходник, не источник деплоя; правка здесь на прод сама не попадает.

## Владение: два файла здесь не наши

`pipeline_utils.py` и `content_db_utils.py` вендорятся из репозитория openclaw — их делят
ещё восемь скриптов конвейера, которые в victory не переезжали. Правка этих двух файлов
в нашем дереве будет затёрта синком. Всё остальное принадлежит victory.

Полная таблица владения и upstream — `VENDOR.md`. Сверка с боевой копией:

```bash
./sync-check.sh                  # отчёт о расхождениях, exit 1 если есть
./sync-check.sh --pull-vendored  # забрать общие модули из openclaw
./sync-check.sh --push-owned     # донести наши файлы до боевого каталога
```

Гоняй `./sync-check.sh` перед работой и перед PR: правка общих модулей ради соседнего
скрипта меняет поведение коллектора, и ни один тест victory этого не поймает.

## Что нельзя трогать «на глаз»

- **Порог дедупа 0.92** и якоря только по `published_to_tg = TRUE`. Порог 0.85 резал валидные
  новости: на коротких русских официальных заголовках baseline сам по себе ~0.85+. Без привязки
  к `published_to_tg` зарезанные события становились якорями для следующих — это стоило 4 дней
  тишины и ~31 потерянного события.
- **`URGENT_ELIGIBLE_TYPES` — ровно пять типов.** `MACRO_ECONOMICS` и `FX_RATE` исключены по
  замеру: 84 срочные публикации за 30 дней против 14.
- **Порядок `MAIN_MODEL_CHAIN`** (`pipeline_utils.py:292`): сначала бесплатные, платный
  `anthropic/claude-sonnet-4` последний и помечен в `PAID_MODELS`. Подняв его выше, ты включишь
  платную модель на кроне каждые 15 минут, молча. ⚠️ Файл вендорный — правь в openclaw, не здесь.

## Контракт с Rails

Единственная точка связи — `app/controllers/webhooks/news_ingest_controller.rb`. Меняя вебхук
со стороны Rails, проверяй Python-конец: он в другом каталоге, на другом языке и не покрыт
ни одним rspec.

## Секреты

`.env` закрыт локальным `.gitignore` и не коммитился ни разу. Держи так: в репозиторий едут
только `.env.example` и `crontab.example`.
