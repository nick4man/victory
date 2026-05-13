# Telegram Work-Bot — Phase 0+1 handoff (для сессии "victory")

В сессии **chat** написан код Phase 0 (онбординг бота в группе) и Phase 1
(скелет лидов, регистрация агентов через /whoami). В этой сессии:
- расширен webhook `allowed_updates` через curl;
- создан `config/telegram_topics.yml` (16 ключей, thread_id пока пустые);
- написаны миграции, модели, сервисы, контроллеры, тесты.

В сессии **victory** нужно прогнать миграции, запустить тесты и собрать
thread_id через discovery. Ниже пошаговая инструкция.

## 1. Прогнать миграции

```bash
# в сессии victory (Ruby 3.2.2 через chruby/rbenv должно быть активно)
bin/rails db:migrate
```

Ожидается 2 новых таблицы:
- `telegram_users` (с unique-индексами по tg_user_id и topnlab_user_id)
- `lead_events` (polymorphic lead_ref, enum-колонки строкой, индексы по anchor)

## 2. Прогнать новые spec

```bash
bundle exec rspec \
  spec/models/telegram_user_spec.rb \
  spec/models/lead_event_spec.rb \
  spec/services/formatters/date_format_spec.rb \
  spec/services/telegram/topic_registry_spec.rb \
  spec/services/lead/intake_spec.rb
```

Ожидается зелёный прогон. Если падает на `BuyerOrder.create!` — возможно
требования к колонкам поменялись после написания специй; адаптировать
build_event helper в lead_event_spec.

## 3. Discovery thread_id для 16 топиков

Webhook уже подписан на `message`, `callback_query`, `my_chat_member` — этого
достаточно (forum_topic_created приходит как поле в обычном message).

**В рабочей TG-группе (`🚀 Виктори | Конвейер сделок`, chat_id=-1003779115845):**
1. Открыть каждый из 16 топиков по очереди.
2. Написать в каждом одно любое сообщение (например, эмодзи `📍`).
3. Бот `@victory62_bot` автоматически:
   - При получении сообщения с `message_thread_id` через `Telegram::WorkBot::TopicDiscovery.maybe_record(msg)` ищет имя топика в поле `reply_to_message.forum_topic_created.name`.
   - Сопоставляет имя с `tg_title` из `config/telegram_topics.yml` через `Telegram::TopicRegistry.key_by_title`.
   - При успешном матчинге сохраняет в `Rails.cache` (запись `telegram:topic_registry:overrides`).

**Альтернатива (если автоматический discovery не сработал):**
Руководитель в каждом топике пишет:
```
/learn_topic apartments     # (заменить ключ соответственно)
```
Ключи в YAML: `dispatcher apartments houses lots commercial rent mortgage appraisal taxes insurance escrow deal sla_reports qna announcements flood`.

**Проверка после discovery:**
```ruby
# в rails console
Telegram::TopicRegistry.missing_keys   # должен вернуть пустой массив
Telegram::TopicRegistry.discovered     # {"apartments" => 4, "houses" => 7, ...}
```

После того как все 16 topic_id discovered — нужно зафиксировать их в `config/telegram_topics.yml` (заменить `~` на реальные id):
```ruby
# в rails console
puts Telegram::TopicRegistry.discovered.to_yaml
```
Полученный YAML вставить вручную в `config/telegram_topics.yml` под `message_thread_id:` каждого топика, закоммитить.

## 4. End-to-end тест Phase 1

### Тест A — /whoami flow
1. В DM с `@victory62_bot` написать: `/whoami brettiney370@gmail.com` (либо email сотрудника, который точно есть в Topnlab).
2. Бот отвечает «Код подтверждения отправлен на …» — на email приходит письмо с 6-значным кодом.
3. В DM присылаем код.
4. Бот: «✅ Готово, …! Аккаунт привязан к Topnlab».
5. В БД появилась запись `TelegramUser` с topnlab_user_id, email, dm_chat_id.

### Тест B — заявка с сайта → карточка в ДИСПЕТЧЕРСКОЙ
1. На сайте `https://victory62.org` заполнить любую форму (быстрая заявка / обратный звонок) — это создаст `Inquiry`.
2. `Inquiry#push_to_work_bot` запустится в `after_create_commit`, вызовет `Lead::Intake.call(source: 'site_form', payload: {...})`.
3. В чате в топике `ДИСПЕТЧЕРСКАЯ` появляется карточка с inline-кнопками маршрутизации.

### Тест C — заявка оценки → карточка в ОЦЕНКА (auto-route)
1. На `/valuations/new` заполнить форму экспресс-оценки.
2. `PropertyValuation#push_to_work_bot` запустится в after_create_commit с source: 'site_valuation'.
3. `Lead::Intake → LeadAnnouncer.resolve_target_topic` → `TopicRegistry.auto_route_for('site_valuation')` → `'appraisal'` → карточка идёт сразу в ОЦЕНКА (минуя ДИСПЕТЧЕРСКУЮ).

## 5. Что НЕ сделано в этой сессии (Phase 1 остатки)

- `Topnlab::Client#import_client` и `#transfer_client` — нужны для Phase 2 (маршрутизация лидов и назначение). Заглушка в `Lead::Intake` — `BuyerOrder` создаётся, но не пишется в CRM.
- Команды `/route`, `/assign`, `/task`, `/stage`, `/note`, `/close` — Phase 2.
- SLA-watchdog jobs — Phase 3.
- Документы (`DocumentRequirement`), TG-DM intake, CRM webhook intake — Phase 4.
- LLM staff responder (`Llm::StaffChatResponder`) — Phase 5.
- Дайджесты — Phase 6.

## 6. Файлы, которые добавлены/изменены в этой сессии

**Новые:**
- `config/telegram_topics.yml`
- `db/migrate/20260521000000_create_telegram_users.rb`
- `db/migrate/20260521000100_create_lead_events.rb`
- `app/models/telegram_user.rb`
- `app/models/lead_event.rb`
- `app/services/telegram/topic_registry.rb`
- `app/services/telegram/work_bot/topic_discovery.rb`
- `app/services/telegram/work_bot/router.rb`
- `app/services/telegram/work_bot/lead_announcer.rb`
- `app/services/telegram/work_bot/commands/base.rb`
- `app/services/telegram/work_bot/commands/whoami.rb`
- `app/services/lead/intake.rb`
- `app/services/lead/intake/site_source.rb`
- `app/services/lead/intake/tg_dm_source.rb`         (stub Phase 4)
- `app/services/lead/intake/manual_source.rb`        (stub Phase 2)
- `app/services/lead/intake/crm_webhook_source.rb`   (stub Phase 4)
- `app/services/formatters/date_format.rb`
- `app/helpers/date_format_helper.rb`
- `app/mailers/telegram_auth_mailer.rb`
- `app/views/telegram_auth_mailer/verification_code.html.erb`
- `app/views/telegram_auth_mailer/verification_code.text.erb`
- `spec/models/telegram_user_spec.rb`
- `spec/models/lead_event_spec.rb`
- `spec/services/formatters/date_format_spec.rb`
- `spec/services/telegram/topic_registry_spec.rb`
- `spec/services/lead/intake_spec.rb`

**Изменённые:**
- `app/services/telegram/client.rb` — добавлены message_thread_id, reply_markup, edit_message_text, delete_message, answer_callback_query, pin_chat_message
- `app/services/telegram/inbound_processor.rb` — вызов `TopicDiscovery.maybe_record` + диспатч в `WorkBot::Router`
- `app/models/inquiry.rb` — `after_create_commit :push_to_work_bot`
- `app/models/property_valuation.rb` — `after_create_commit :push_to_work_bot`

**Webhook изменения через API (без файлов):**
- `setWebhook?allowed_updates=["message","callback_query","my_chat_member"]` (forum-events приходят как часть message)
