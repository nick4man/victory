# Runbook: антиспам чат-бота сайта (issue #219)

_Актуален на 13.11.26. Пайплайн обработки входящего сообщения чат-виджета
(`Chat::MessagesController#create`), слои по порядку:_

1. **Rate-limit** — 5 сообщений/мин на visitor_token (Redis), без изменений.
2. **Спам-фильтр до LLM** (`Llm::SpamFilter.classify`) — дешевле ScopeGuard,
   поэтому стоит первым:
   - IP отправителя в `spam_blocked_entries` (`entry_type = ip`, включая
     CIDR-подсети из firehol-фидов) → тихий дроп: сообщение сохраняется,
     помечается `metadata.excluded_from_llm = true` (не попадает в контекст
     следующих вопросов), LLM не зовётся, лид/эскалация не создаются.
     В канал конверсации его эхо уже транслировано до фильтра (Turbo) —
     роли это не меняет: ответа ассистента спамер не получает.
   - URL из текста → нормализация (`Llm::SpamUrls.normalize`: lowercase,
     без `www`/query/якоря/порта/финальной точки, IDN → punycode) →
     проверка по `spam_blocked_entries`. Приоритет: blocked URL (точный
     host+path) → blocked домен (любой путь) → suspect (hit и проход).
     Allowlist (Tranco Top-10k) снимает ТОЛЬКО доменный блок; путь на белом
     домене блочится.
   - Эвристики (стоп-слова, `hxxp://`, шортенеры из hagezi-фида) → новый
     домен в карантин: `status = suspect`, `source = local`. Белый домен
     блочится только на уровне пути (`t.me/spam_channel`), корень не трогаем.
3. **ScopeGuard** (инъекции/off-topic) — как раньше.
4. **LlmReplyJob → ChatResponder** — обычный путь.

Карантин → блок: ЛОКАЛЬНАЯ suspect-запись (`source = local`) становится
`blocked`, когда один домен прилетел от ≥3 разных IP (`hit_tokens`, окно
24 ч). Служебные записи фидов (например, шортенеры — они suspect) кворумом
не блокируются — их статусом управляет синк. Отдельный путь повышения:
suspect-домен/URL из сообщения от IP из ipsum (спам-IP) → сразу `blocked`.

## Пополнение и протухание списков

- `Llm::SpamFeeds::SyncJob` (cron `spam_feeds_sync`, ежедневно 03:20 MSK,
  очередь `low_priority`): доменные фиды (hagezi TIF/Fake в adblock-формате,
  matomo referrer-spam, Phishing.Database домены → `blocked`; hagezi
  shorteners → `suspect`) и URL-фиды (Phishing.Database phishing-links →
  `blocked` на уровне полного host+path, не домена; URLhaus → тоже URL-фид,
  но keyless-экспорты abuse.ch отдают 410 — нужен бесплатный
  Auth-Key с auth.abuse.ch, полный URL с ключом кладётся в ENV
  `URLHAUS_EXPORT_URL`, без ключа фид пропускается) и IP-фиды (ipsum
  level 3, firehol cleantalk/stopforumspam/botscout 7d) → `blocked`;
  Tranco Top-1M (официальный zip, распаковка `Llm::SpamFeeds::Zip`) →
  `spam_allowlist_entries` (верхние 10k, `manual = false`).
- Резко усечённая выгрузка (меньше `min_rows` записей источника) отклоняется
  целиком — непустой обрезок не должен стирать боевой список. Ответы
  крупнее 100 МБ отклоняются (защита ежедневного job от OOM).
- Пакетная загрузка `insert_all` чанками по 1000, два прохода по телу фида
  (подсчёт → запись): в памяти живёт только чанк, таблица в объекты
  ActiveRecord не материализуется. Идемпотентен; объёмы пишет в лог
  как `[SpamFeeds] синк завершён: {...}`; недоступный фид — с нулём.
- **Протухание**: после удачной выгрузки записи, исчезнувшие из объединения
  свежих фидов их типа, soft-delete'ятся — выбывший из публичных списков
  адрес не блочится вечно. Пустой/битый ответ фида НЕ стирает прежние
  записи (сбой источника ≠ пустой список). `source = local` синк не
  трогает вообще, кроме повышения `suspect → blocked` подтверждённым фидом.
- Manual-записи allowlist (`manual = true`: ручные исключения и наш домен
  из сид-миграции) синк не стирает.
- **Первичный запуск**: до первого успешного Tranco-синка allowlist
  содержит только наш домен из сид-миграции — защита популярных доменов
  (YouTube, мессенджеры) и шортенеров ещё не активна; фидовые blocked-списки
  при этом работают сразу. Проверить наполнение: `SpamAllowlistEntry.count`
  (ожидается ~10k после первого прогона `spam_feeds_sync`).

## JSON API модерации (основной способ)

Token-gated эндпоинты (`?token=$ADMIN_TOKEN` — отдельный секрет админки,
НЕ общий с вебхуками, у каждого вебхука свой секрет из ENV; CSRF снят только
для вызовов с ВАЛИДНЫМ токеном — мусорный `?token` в
контексте админской cookie-сессии запрос не пропускает):

- `POST /admin/spam_blocked_entries` — ручная блокировка. Параметры:
  `url` (нормализация та же, что у фильтра: www/IDN/порт/dot-сегменты
  сводятся к одному ключу), опционально `status` (`blocked` по умолчанию,
  `suspect` — в карантин). Источник записи принудительно `local`:
  синк фидов её не стирает. Ответ: `201 { ok: true, entry: {...} }`.
- `GET /admin/spam_blocked_entries` — выборка. Фильтры: `source`,
  `status`, `entry_type`; пагинация `limit` (≤500, по умолчанию 100) +
  `offset`. По умолчанию только действующие записи; `with_deleted=1`
  добавляет снятые блоки (в ответе у каждой записи есть `deleted_at`).
- `DELETE /admin/spam_blocked_entries/:id` — разблокировка (soft-delete,
  действует немедленно; для `entry_type = ip` сбрасывает и CIDR-кеш).

Ручная работа через Rails console (ниже) — fallback, когда API недоступен.

## Жалоба «бот не отвечает на моё сообщение» / ложная блокировка

1. Найти конверсацию и глазами на `metadata['security_events']` — там
   последние 50 событий с `kind = spam_ip | spam_link | injection` и
   excerpt текста.
2. Лог web-контейнера: строки `[SpamFilter] reason=...`.
3. Проверить запись: `SpamBlockedEntry.find_by(entry_type: :domain,
   value: '<домен>')` — статус, source, hits (поиск в консоли по value
   работает, уникальность в БД — по value_digest).
4. Разблок **локальной** записи: `DELETE /admin/spam_blocked_entries/:id`
   (см. раздел выше) либо `entry.update!(deleted_at: Time.current)` —
   soft-delete действует немедленно.
5. Разблок **фидовой** записи: добавить домен в allowlist
   (`POST`-записи в API нет — `SpamAllowlistEntry.create!(domain: '...', manual: true)`
   в консоли) — allowlist
   снимает доменный блок, но позволяет blocked-URL на этом домене; чтобы
   снять и их, удалить записи `entry_type = url` этого домена через API.
   Важно: allowlist-запись без `manual = true` сотрётся следующим синком.
6. Если домен сидит во внешнем фиде и ложное срабатывание системное —
  разобрать с источником (у hagezi есть форма ложных позитивов) — синк
  вернёт запись из фида при следующем прогоне.

## Проверка здоровья синка

- Sidekiq → recurring jobs → `spam_feeds_sync` (последний прогон без
  ошибок).
- Лог sidekiq: `[SpamFeeds] синк завершён: {"hagezi_tif"=>…, …}` — нули по
  всем фидам = сеть/источники недоступны, нового ничего не доставлено
  (allowlist и старые записи при этом продолжают работать).
- `SpamBlockedEntry.group(:source, :status).count` — ожидаемые объёмы:
  hagezi_tif/фишинг — сотни тысяч доменов, ipsum/firehol — тысячи IP.
  Заметный перекос в `deleted_at` говорит о массовом протухании — смотреть,
  не сломался ли формат фида.

## Спеки

`spec/services/llm/spam_{urls,filter}_spec.rb`,
`spec/services/llm/spam_feeds/sync_job_spec.rb`,
`spec/models/spam_blocked_entry_spec.rb`,
`spec/requests/chat/messages_spec.rb` (блок «антиспам»),
фикстура zip: `spec/fixtures/files/tranco-top.zip`.
