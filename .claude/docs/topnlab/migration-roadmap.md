# Topnlab → собственная CRM: roadmap миграции

> Стратегический фундамент. Не план на месяц, а гид для постепенного reverse-engineering domain-модели и переноса.
> Обновляй когда появляются конкретные milestones или меняется приоритизация.

## Why migrate

1. **Контроль и расширение функциональности** — Topnlab black-box; мы не можем добавить что нужно агентству (custom workflows, AI-аналитика, intra-агент-связь).
2. **Стоимость** — лицензии Topnlab vs собственная инфра при росте.
3. **Интеграция с нашей AI-стеком** — site chatbot, audit-engine, embedding-search уже живут в victory; CRM на нашей стороне = единая БД, единые pgvector-эмбеддинги, единые tools для site chatbot.
4. **TG staff bot уже наш** — `app/services/telegram/work_bot/` уже играет роль CRM-уведомлений (lead_announcer, escalation_notifier). Шаг к полноценной CRM минимальный.

## Не цели миграции (что НЕ переделываем)

- Старые исторические данные Topnlab за пределами активного use — оставляем readonly snapshot
- Дублирование UX Topnlab — наш UX строим под наши процессы
- Полная feature-parity с Topnlab сразу — миграция инкрементальная

## Mapping: Topnlab → victory62

### Уже в victory (миграция = усиление существующего)

| Topnlab сущность | Victory62 эквивалент | Файл/таблица | Что докрутить |
|---|---|---|---|
| Объекты недвижимости | `Property` model | `app/models/property.rb`, `properties` table | Поля синка из Topnlab (см. `listings-and-mls.md`); пока живёт `external_listings` + `mls_listings` для сырого импорта |
| Заявки клиентов | `Inquiry` model | `app/models/inquiry.rb` | Расширить под Topnlab-полей (стадии, ответственный, источник); AASM-states |
| Лиды | `Inquiry` + `LeadEvent` | `app/models/lead_event.rb` | Полный lead lifecycle; assignment to agents |
| Услуги | (NEW) `Service` model? | — | Topnlab services как domain-entity у нас — TBD |
| Отчёты | `CrmReport` | `app/models/crm_report.rb` | Уже есть; нужны Topnlab-style разделы (Продавцы, Покупатели, Услуги, …) |
| Документы | `Document` | `app/models/document.rb` | Active Storage attachments; нужна категоризация по Topnlab-разделам |

### Из call-center.md

| Topnlab фича | Victory62 эквивалент | Где разместить |
|---|---|---|
| Создание заявки из звонка | TG staff bot lead_announcer | `app/services/telegram/work_bot/lead_announcer.rb` уже создаёт; добавить telephony webhook |
| Смена ответственного | `Inquiry.assigned_agent_id` | будет в `app/services/lead/intake.rb` |
| Запись звонков | (NEW) Active Storage attachment на Inquiry | TBD |

### Из clients-fields.md

| Topnlab сущность | Victory62 эквивалент | Notes |
|---|---|---|
| Физ. лица | `User` (если клиент = юзер) или новая `Client`-модель | Сейчас Devise отключен; `current_user → nil`. Может Client отдельная модель без auth, а User для агентов? |
| Юр. лица | (NEW) `LegalClient` | TBD; редко используется |
| Дети клиентов | дочерние записи `Client.children` | редко используется |
| Подписанты | (NEW) `Signer` polymorphic | TBD |

### Чисто наше (нет в Topnlab)

- AI chatbot на сайте (`app/services/llm/chat_responder.rb`)
- Investment audit (`audit_engine` sidecar)
- Express valuation (hedonic + bootstrap CI)
- News + Embeddings (pgvector semantic search)
- Mortgage calculator (22 банковские программы)
- TG staff bot (commands, topics, escalations)

## Phases миграции (high-level, без сроков)

### Phase 0 — Текущее состояние (где мы сейчас)

- ✅ Двусторонняя sync с Topnlab (объекты, фото, заявки) через 8 джобов
- ✅ Webhook от Topnlab при изменениях
- ✅ TG staff bot работает рядом с Topnlab как доп. канал
- ⚠️ Все CRM-операции агенты делают в Topnlab UI

### Phase 1 — Read-replica + own UI

Цель: агенты могут смотреть свои leads/inquiries в victory62 admin (read-only из Topnlab sync).

- Расширить `Inquiry`/`LeadEvent` под Topnlab поля
- Создать `Admin::CrmController` страницы (просмотр лидов агента, фильтры)
- Auth: query-param token или (вернуть) Devise

### Phase 2 — Write в victory, sync обратно в Topnlab

Цель: агенты могут менять lead-stage, добавлять заметки, в victory62 — и оно sync'ится в Topnlab.

- API endpoint на стороне Topnlab `/api/leads/{id}/note` (push) → 1 джоб уже есть: `topnlab_note_push_job.rb`
- Stage transitions через `Inquiry.state_machine` → push в Topnlab
- TG staff bot принимает команды и пушит изменения

### Phase 3 — Telephony внутри victory

Цель: звонки регистрируются нашими, не Topnlab.

- Asterisk webhook → `Webhooks::TelephonyController` (NEW)
- Создание Inquiry из звонка
- (по желанию) запись/транскрипт звонков

### Phase 4 — Topnlab отключается

Цель: Topnlab остаётся только для исторических данных (frozen).

- Все DAU операции в victory
- Сохраняется readonly Topnlab snapshot
- Sync stops

## Полезные ссылки

- `app/services/topnlab/` — текущая интеграция
- `app/services/mls_sync/` — мапперы для MLS feeds
- `app/jobs/topnlab_*_job.rb` — 6 jobs handling sync
- `.claude/docs/topnlab/listings-and-mls.md` — API reference
- `.claude/agents/topnlab-api-expert.md` — узкий агент по этим докам

## Open questions (TBD как раз решения подсядут)

1. **Куда деть Topnlab Services** (объект продажи как услуга — broker, юрист, страховка)? Сейчас вроде нет аналога в victory.
2. **Какой формат stage transitions?** AASM встроенный в Inquiry или отдельный StateLog?
3. **Legal clients (ЮЛ)** — нужны вообще, или MVP можно без них?
4. **Заметки агента** на Inquiry — простой text field, или богатый Note model с timestamps + author?
