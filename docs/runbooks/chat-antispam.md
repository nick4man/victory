# Runbook: антиспам чат-бота сайта (issue #219)

Пайплайн обработки входящего сообщения чат-виджета
(`Chat::MessagesController#create`), слои по порядку:

1. **Rate-limit** — 5 сообщений/мин на visitor_token (Redis), без изменений.
2. **Спам-фильтр до LLM** (`Llm::SpamFilter.classify`) — дешевле ScopeGuard,
   поэтому стоит первым:
   - IP отправителя в `spam_blocked_entries` (`entry_type = ip`) → тихий
     дроп: сообщение сохраняется, в чат ничего не уходит, LLM не зовётся,
     лид/эскалация не создаются.
   - URL из текста → нормализация (`Llm::SpamUrls.normalize`: lowercase,
     без `www`/query/якоря, IDN → punycode) → проверка по
     `spam_blocked_entries` (`domain` — любой путь, `url` — точный
     host+path). `blocked` → тихий дроп; `suspect` → hit, сообщение
     проходит дальше.
   - Эвристики (стоп-слова, `hxxp://`, шортенеры из hagezi-фида) → новый
     домен в карантин: `status = suspect`, `source = local`. Белый домен
     (allowlist) блокируется только на уровне пути (`t.me/spam_channel`),
     корень не трогаем.
3. **ScopeGuard** (инъекции/off-topic) — как раньше.
4. **LlmReplyJob → ChatResponder** — обычный путь.

Карантин → блок: запись `suspect` становится `blocked`, когда от ≥3 разных
сессий/IP (`hit_tokens`, окно 24 ч) прилетел один домен. Новые спам-домены
так режутся без деплоя.

## Пополнение списков

- `Llm::SpamFeeds::SyncJob` (cron `spam_feeds_sync`, ежедневно 03:20 MSK,
  очередь `low_priority`): доменные фиды (hagezi TIF/Fake/shorteners,
  matomo referrer-spam, Phishing.Database, URLhaus) и IP-фиды (ipsum
  level 3, firehol cleantalk/stopforumspam/botscout 7d) → `blocked`;
  снапшот Cisco Umbrella Top-1M → `spam_allowlist_entries` (верхние 10k).
  Идемпотентен, объёмы пишет в лог как `[SpamFeeds] синк завершён: {...}`.
- Локальные находки бота — `source = local`, только `suspect` (кроме
  ручных подтверждений человеком).

## Жалоба «бот не отвечает на моё сообщение» / ложная блокировка

1. Найти конверсацию и глазами на `metadata['security_events']` — там
   последние 50 событий с `kind = spam_ip | spam_link | injection` и
   excerpt текста.
2. Лог web-контейнера: строки `[SpamFilter] reason=...`.
3. Проверить запись: `SpamBlockedEntry.find_by(entry_type: :domain,
   value: '<домен>')` — статус, source, hits. Если ложная:
   `entry.update!(deleted_at: Time.current)` (soft-delete, индекс
   освобождается сразу) либо `status: :suspect`, если домен сомнительный.
4. Если домен сидит во внешнем фиде — локальный soft-delete живёт до
   следующего синка фидов: запись из фида upsert'нется заново. Такие
   случаи разбирать с источником (hagezi имеет форму ложных
   срабатываний) или переводить запись в allowlist.

## Проверка здоровья синка

- Sidekiq → recurring jobs → `spam_feeds_sync` (последний прогон без
  ошибок).
- Лог sidekiq: `[SpamFeeds] синк завершён: {"hagezi_tif"=>…, …}` — нули по
  всем фидам = сеть/GitHub недоступны, синк не доставил ничего (allowlist
  и старые записи при этом продолжают работать).
- `SpamBlockedEntry.group(:source, :status).count` — ожидаемые объёмы:
  hagezi_tif/фишинг — сотни тысяч доменов, ipsum/firehol — тысячи IP.

## Спеки

`spec/services/llm/spam_{urls,filter}_spec.rb`,
`spec/services/llm/spam_feeds/sync_job_spec.rb`,
`spec/models/spam_blocked_entry_spec.rb`,
`spec/requests/chat/messages_spec.rb` (блок «антиспам»).
