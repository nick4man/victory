# Runbook: антиспам чат-бота сайта (issue #219)

_Актуален на 12.11.26. Пайплайн обработки входящего сообщения чат-виджета
(`Chat::MessagesController#create`), слои по порядку:_

1. **Rate-limit** — 5 сообщений/мин на visitor_token (Redis), без изменений.
2. **Спам-фильтр до LLM** (`Llm::SpamFilter.classify`) — дешевле ScopeGuard,
   поэтому стоит первым:
   - IP отправителя в `spam_blocked_entries` (`entry_type = ip`, включая
     CIDR-подсети из firehol-фидов) → тихий дроп: сообщение сохраняется,
     помечается `metadata.excluded_from_llm = true` (не попадает в контекст
     следующих вопросов), в чат ничего не уходит, LLM не зовётся,
     лид/эскалация не создаются.
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
`blocked`, когда от ≥3 разных сессий/IP (`hit_tokens`, окно 24 ч) прилетел
один домен. Служебные записи фидов (например, шортенеры) кворумом не
блокируются — их статусом управляет синк.

## Пополнение и протухание списков

- `Llm::SpamFeeds::SyncJob` (cron `spam_feeds_sync`, ежедневно 03:20 MSK,
  очередь `low_priority`): доменные фиды (hagezi TIF/Fake/shorteners,
  matomo referrer-spam, Phishing.Database, URLhaus) и IP-фиды (ipsum
  level 3, firehol cleantalk/stopforumspam/botscout 7d) → `blocked`;
  Tranco Top-1M (официальный zip, распаковка `Llm::SpamFeeds::Zip`) →
  `spam_allowlist_entries` (верхние 10k, `manual = false`).
- Пакетная загрузка `insert_all` сотнями; идемпотентен; объёмы пишет в лог
  как `[SpamFeeds] синк завершён: {...}`.
- **Протухание**: после удачной выгрузки записи источника, исчезнувшие из
  фида, soft-delete'ятся — выбывший из публичных списков адрес не блочится
  вечно. Пустой/битый ответ фида НЕ стирает прежние записи (сбой источника
  ≠ пустой список). `source = local` синк не трогает вообще.
- Manual-записи allowlist (`manual = true`: ручные исключения и наш домен
  из сид-миграции) синк не стирает.

## Жалоба «бот не отвечает на моё сообщение» / ложная блокировка

1. Найти конверсацию и глазами на `metadata['security_events']` — там
   последние 50 событий с `kind = spam_ip | spam_link | injection` и
   excerpt текста.
2. Лог web-контейнера: строки `[SpamFilter] reason=...`.
3. Проверить запись: `SpamBlockedEntry.find_by(entry_type: :domain,
   value: '<домен>')` — статус, source, hits.
4. Разблок **локальной** записи: `entry.update!(deleted_at: Time.current)`
   (soft-delete действует немедленно).
5. Разблок **фидовой** записи: добавить домен в allowlist
   (`SpamAllowlistEntry.create!(domain: '...', manual: true)`) — allowlist
   снимает доменный блок, но позволяет blocked-URL на этом домене; чтобы
   снять и их, soft-delete'ить записи `entry_type = url` этого домена.
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
