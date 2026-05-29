# futureCrm.md — переход с Topnlab на собственную CRM

> Стратегический документ, не план на месяц. Фундамент для миграции. Обновляй когда решаются конкретные milestones.

## Why migrate

1. **Контроль фич**: Topnlab black-box → нельзя добавить custom workflow, AI-аналитику, intra-agent linking
2. **Стоимость**: лицензии Topnlab vs собственная инфра при росте агентства
3. **AI-стек уже наш**: site chatbot, audit-engine, embedding-search уже в victory62 → единая БД, единые pgvector, единые tools для chatbot
4. **TG staff bot уже играет роль CRM** (`work_bot/lead_announcer.rb`, `escalation_notifier.rb`) — миграция = усиление существующего

## Что НЕ цель

- Полная feature-parity с Topnlab сразу
- Дублирование Topnlab UX
- Переписать всю историю Topnlab-данных

## Mapping (Topnlab → victory62)

### Уже в victory (миграция = усиление существующего)

| Topnlab entity | Victory model | Файл | Что докрутить |
|---|---|---|---|
| Объект недвижимости | `Property` | `app/models/property.rb` | Поля из Topnlab listings-and-mls.md; `external_listings` + `mls_listings` для raw import |
| Заявка клиента | `Inquiry` | `app/models/inquiry.rb` | Topnlab stages, ответственный, источник; AASM-states |
| Лид | `Inquiry` + `LeadEvent` | `app/models/lead_event.rb` | Полный lifecycle с auto-assign |
| Услуга | (NEW) `Service` model? | — | Topnlab `service` объект ≠ наш domain, TBD |
| Отчёт | `CrmReport` | `app/models/crm_report.rb` | Topnlab-style sections (Продавцы/Покупатели/Услуги) |
| Документ | `Document` | `app/models/document.rb` | Категоризация по Topnlab разделам |

### Из call-center API

| Topnlab feature | Victory destination |
|---|---|
| Заявка из звонка | TG staff bot lead_announcer + telephony webhook (NEW) |
| Смена ответственного | `Inquiry.assigned_agent_id` + `app/services/lead/intake.rb` |
| Запись звонков | (NEW) Active Storage attachment на Inquiry |

### Из clients-fields.md

| Topnlab entity | Victory destination |
|---|---|
| Физ. лица | `User` (если client = staff) ИЛИ новая `Client` модель (без auth) |
| Юр. лица | (NEW) `LegalClient` (редко используется) |
| Дети клиентов | `Client.children` polymorphic |
| Подписанты | (NEW) `Signer` polymorphic |

### Чисто наше (нет в Topnlab)

- AI chatbot на сайте
- Investment audit (sidecar `audit_engine`)
- Express valuation (hedonic + bootstrap CI)
- News + embeddings (pgvector semantic search)
- Mortgage calculator (22 банковские программы)
- TG staff bot с commands/topics/escalations

## Phases миграции (без сроков)

### Phase 0 — текущее состояние

- Двусторонняя sync с Topnlab (8 jobs)
- Webhook Topnlab → victory
- TG staff bot работает рядом
- Все CRM-операции агенты делают в Topnlab UI

### Phase 1 — Read-replica + own UI

Цель: агенты могут смотреть свои leads/inquiries в victory62 admin (read-only sync из Topnlab).

- Расширить `Inquiry`/`LeadEvent` под Topnlab поля
- `Admin::CrmController` пакет страниц (фильтры, лиды агента)
- Auth: query-param token или вернуть Devise

### Phase 2 — Write в victory, sync обратно

Цель: правки в victory → push в Topnlab.

- API endpoint Topnlab `/api/leads/{id}/note` (push) — джоб уже есть: `topnlab_note_push_job.rb`
- Stage transitions через `Inquiry.state_machine` → push
- TG staff bot принимает команды и пушит

### Phase 3 — Telephony внутри victory

- Asterisk webhook → `Webhooks::TelephonyController` (NEW)
- Создание Inquiry из звонка
- (Опц.) запись/транскрипт звонков

### Phase 4 — Topnlab выключается

- Все DAU операции в victory
- Topnlab остаётся readonly snapshot
- Sync stops

## Key domain entities (наша модель собственной CRM)

| Entity | Уже есть? | Где |
|---|---|---|
| `Property` | ✅ | `app/models/property.rb` |
| `User` (agent) | ✅ | `app/models/user.rb` (Devise disabled) |
| `Client` (физ. лицо) | ⚠️ | TBD — пока через Inquiry.client_name/phone |
| `LegalClient` (юр. лицо) | ❌ | NEW |
| `Inquiry` (заявка) | ✅ | `app/models/inquiry.rb` |
| `LeadEvent` | ✅ | `app/models/lead_event.rb` |
| `Conversation` (chat) | ✅ | `app/models/conversation.rb` |
| `ChatMessage` | ✅ | `app/models/chat_message.rb` |
| `CrmReport` | ✅ | `app/models/crm_report.rb` |
| `Document` | ✅ | `app/models/document.rb` |
| `Note` | ✅ | `app/models/note.rb` |
| `Service` (услуга) | ❌ | TBD |
| `Order` (сделка) | ⚠️ | `BuyerOrder` есть |
| `Signer` | ❌ | NEW |

## Open questions

1. **Куда деть Topnlab Services**? (продажа как услуга — broker, юрист, страховка). Нужна `Service` модель?
2. **Stage transitions** — AASM на Inquiry или отдельный `InquiryStateLog`?
3. **Legal clients (ЮЛ)** — MVP без них?
4. **Заметки на Inquiry** — text field или богатый `Note` с timestamps + author?

## Связанные агенты и доки

- **`topnlab-api-expert`** — основной агент для миграционных решений и API-вопросов
- **`.claude/docs/topnlab/`** — 4 файла API + README + migration-roadmap
- **`telegram-staff-bot-dev`** — TG bot который уже часть будущей CRM
- **`rails-architect`** — для design новых domain entities
