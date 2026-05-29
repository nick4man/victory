# Live-test playbook — Phase 4-6 + Phase 11 управление

> Verify on prod что новые features работают end-to-end. Группы упорядочены
> от safest (read-only / нон-destructive) к destructive (создаёт записи / DM-spam).
> Все cross-check команды запускать в `docker compose exec -T web bin/rails runner '...'`.

**Prerequisites:** bot `@anvictorybot`, рабочая группа `🚀 Виктори | Конвейер сделок`
(`-1003779115845`), как minimum 1 director + 1 manager + 1 agent активные в TelegramUser.

**Smoke first:** `curl https://victory62.org/admin/health.json?token=$ADMIN_TOKEN` →
ожидаем `status: "ok"` и все 4 checks (db/redis/sidekiq/topnlab) = true.

---

## 🧊 Группа A — read-only health checks (run anytime)

### A1. `/admin/health.json` структура
```bash
curl -s "https://victory62.org/admin/health.json?token=$ADMIN_TOKEN" | jq .
```
- ✅ `status: "ok"`
- ✅ `bot.directors_active >= 1`, `managers_active >= 1`, `assignable >= 2`
- ✅ `operational` содержит: `documents_open`, `documents_overdue`, `tg_dm_inquiries_24h`,
  `topnlab_webhook_last_seen` (может быть `null` если webhooks не приходили — это OK)
- ✅ `alerts_suppressed_5min: {}` (или содержит throttle-keys — это норм)

### A2. Bot reachable via webhook
- В DM с `@anvictorybot` отправь любое короткое слово ("ping")
- ✅ Бот не падает — либо отвечает (если staff Q&A flow), либо ничего
- Cross-check: `BotCommandLog.recent.first` — должна быть свежая запись (created_at < 1min ago)

### A3. `/help` в DM
- `/help` в DM с ботом
- ✅ Список команд по роли (если зарегистрирован) или public-only

---

## 🟡 Группа B — document checklist (Phase 4A-4C + 4G)

### B1. `/doc init` на якорной карточке
**Setup:** Заполни форму на сайте `/contacts` либо used `/lead +79991234567 Test, бюджет 5 млн`
→ карточка появится в #ДИСПЕТЧЕРСКОЙ.

- В рабочей группе reply на якорь: `/doc init`
- ✅ Бот: «📋 Чек-лист создан по шаблону `default_sale` / `apartment_sale` / etc.
  Добавлено: N. ...»
- Cross-check: `DocumentRequirement.where(lead_event: <id>).count` ≥ 3

### B2. `/doc passport+ snils?` batch apply
- reply на тот же якорь: `/doc passport+ snils?`
- ✅ «✅ Обновлено: 2 документ(ов)»
- Cross-check: `DocumentRequirement.find_by(lead_event:, kind: 'passport_main').status == 'received'`
  и `kind: 'snils'` → `'requested'`

### B3. `/doc` status display
- reply на якорь: `/doc`
- ✅ HTML-форматированный список с группами: ✅ ГОТОВЫ / 📥 ПОЛУЧЕНЫ / ⏳ ЗАПРОШЕНЫ /
  ❓ НЕ ЗАПРОШЕНЫ / 🚫 ОТКЛОНЕНЫ. Progress N/M (X%)
- ✅ Запрошенные показывают SLA countdown («⏰ ещё Yч» или «⚠️ просрочка X%»)

### B4. `/doc <id>@reject:reason` rejection
- reply: `/doc snils@reject:client_refused`
- ✅ Reply «✅ Обновлено: 1»
- Cross-check: `DR.find(<id>).metadata['rejection_reason']` == "client_refused"

### B5. **AutoMatch (Phase 4G)** — photo → DR auto-link
**Setup:** Клиент должен прислать photo (или используй test account как клиент).
ClientDocument должен быть привязан к Inquiry того lead'а.

- В DM с ботом со staff-test-account клиент отправляет фото паспорта
- ✅ ParserJob запускается → OCR через Yandex Vision → confidence > 0.7
- ✅ DR `passport_main` (если был `requested`) → `received`
- ✅ Manager (assigned_to) получает DM: «✅ Документ автопривязан…»
- Cross-check: `DocumentRequirement.find_by(received_via_client_document_id: <cd_id>)` exists

---

## 🟡 Группа C — client TG-DM intake (Phase 4D + 4H)

### C1. Anonymous client message → IntentClassifier → Inquiry
**Use a fresh TG account (не staff)** для теста.

- Из нового account напиши боту в DM: «Хочу 2-комн квартиру в Канищево до 7 млн»
- ✅ Бот: «✅ Заявка принята! Агент свяжется в течение часа.»
- ✅ В #ДИСПЕТЧЕРСКОЙ появилась карточка с inline-кнопками маршрутизации
- Cross-check: `Inquiry.where(source: 'tg_dm', client_tg_user_id: <your_tg_id>).recent.first`
  exists с `attribution_source='tg_dm'`

### C2. Spam intent → silently dropped
- С того же fresh account: «Купи биткоины! +50% прибыли!»
- ✅ Бот не отвечает (silent drop)
- Cross-check: Redis `GET client_intake:spam_24h` — increment counter

### C3. Test intent → soft greeting
- Из fresh account: «привет»
- ✅ Бот: «Здравствуйте! Я бот АН Виктори — могу помочь с подбором…»

### C4. **Cross-channel match (Phase 4H)** — site form → TG-DM same phone
- Заполни форму на /contacts с phone `+79991234567`
- Затем с TG account напиши в DM боту: «Я подавал заявку, есть новости?»
  - (бот не знает phone — match по phone требует чтобы клиент его дал; альтернатива:
    напиши с того же phone-linked TG если staff линковал)
- ✅ Если phone-match сработал: бот отвечает «👋 Спасибо, что вернулись!» и
  существующий lead'у в metadata['client_history'] добавляется entry
- Cross-check: `LeadEvent.find(<id>).metadata['client_history']` array, last entry
  `channel: 'tg_dm'`, `match_strategy: 'phone_e164'`

---

## 🟠 Группа D — SLA reminders cron (Phase 4F)

### D1. Hourly cron fires
- Cron `document_reminder` runs `0 * * * *`. Ждать следующий :00.
- ✅ Sidekiq job `DocumentReminderJob` отрабатывает (Sidekiq UI: `/sidekiq?token=`)
- ✅ Логи: `[DocumentReminderJob] done: {processed: N, tier1: X, ...}`

### D2. Synth overdue DR → tier 1 reminder
**Setup:** Создай DR с `requested_at = 36.hours.ago`, kind=`passport_main` (SLA=1d),
lead должен иметь `client_tg_user_id` для tier-1 (client DM).

```bash
docker compose exec -T web bin/rails runner '
lead = LeadEvent.where.not(metadata: nil).find { |l| l.lead_ref.is_a?(Inquiry) && l.lead_ref.client_tg_user_id }
DocumentRequirement.create!(lead_event: lead, kind: "passport_main",
                            status: "requested", requested_at: 36.hours.ago)
DocumentReminderJob.new.perform
'
```
- ✅ Client получает DM: «👋 Здравствуйте! Напоминаю — для оформления сделки…»
- Cross-check: `DR.find(<id>).reminder_count == 1`, `last_reminder_at` present,
  `metadata['last_reminder_tier'] == 1`

### D3. Tier 2 — assignee DM (factor >= 2.0)
**Setup:** `requested_at = 5.days.ago`, kind=`inn` (SLA=2d → factor=2.5).
- Manually trigger job → ✅ DM лиду's assignee
- Cross-check: assignee dm_chat_id received message

### D4. Quiet hours skip (21-07 MSK)
- Cron в quiet hours: job returns `:quiet_hours_skip` без отправки DM
- Verify in logs: `[Kpi::MorningDigestJob] weekend skip` style messages

---

## 🟠 Группа E — Phase 11 management commands

### E1. `/reassign <task_id> @user`
**Setup:** Один из staff должен иметь open Task. Manager-only.
- В DM боту: `/reassign 142 @new_user`
- ✅ Reply: «🔄 Задача ##{id} передана: <prev> → <new>»
- ✅ Новый assignee получает DM-карточку с кнопками `[▶][✅]`
- ✅ Старая DM-карточка прежнего assignee теряет кнопки (Iter 34)
- ✅ Прежний assignee получает DM «🔄 Задача передана»
- Cross-check: `Task.find(<id>).assignee_id == new_user_id`, `notified_at: nil` (fresh),
  `tg_message_id: <new>` (new dispatch)

### E2. `/reopen <task_id>` (24h window)
**Setup:** Task в status='done' за < 24h.
- `/reopen 142`
- ✅ Reply: «↩️ Задача #142 переоткрыта (была done).»
- ✅ Task status → 'open', completed_at → nil, acked_method → nil
- ✅ Если manager reopen'нул чужую → assignee получает DM

### E3. `/demote @user` (manager → agent)
**Setup:** Test target = manager (not director).
- Manager-only: `/demote @testuser`
- ✅ Reply: «⬇️ @testuser понижен → role=agent, is_manager=false»
- ✅ Target получает DM «Тебя понизили до agent»
- ✅ Other managers получают audit DM
- Cross-check: `TelegramUser.find_by_username('testuser').is_manager? == false`

### E4. `/deactivate @user [confirm]` two-phase
- `/deactivate @testuser` (без confirm) → diagnosis preview (status, open tasks, leads)
- `/deactivate @testuser confirm` → apply
- ✅ status='inactive', assignable=false
- ✅ Target DM + audit DM to managers

### E5. `/resume_batch <id>` (director only, 24h window)
**Setup:** Voice batch со status=`expired` или `cancelled`.
- Director: `/resume_batch <id>`
- ✅ Reply: «🔄 TaskBatch ##{id} переоткрыт — проверь preview в DM.»
- ✅ Status → `pending_confirm`, preview сообщение повторно отправлено

---

## 🟢 Группа F — Phase 5 staff Q&A

### F1. **`#ВОПРОС-ОТВЕТ` topic + @mention**
- В qna топике (или любом другом, кроме quiet): `@anvictorybot какие лиды у Ивана?`
- ✅ Бот отвечает с tool-вызовом `lookup_lead` или `agent_status`
- ✅ Tool name появляется в footer `<i>(used_tools: ...)</i>`
- Cross-check: `StaffQuestion.recent.first` запись с `kind`, `llm_model`, `answer_text`

### F2. **document_checklist_status tool (Phase 5.1)**
- В qna: `@anvictorybot сколько документов открыто на лиде #<id>?`
- ✅ Бот возвращает aggregate: total=N, counts={requested: X, received: Y, …}, overdue
- ✅ Used tool: `document_checklist_status`

### F3. **Cross-topic mention (Phase 5.2)**
- В #КВАРТИРЫ (или любой non-quiet topic): `@anvictorybot статус documents лида #145?`
- ✅ Бот отвечает в том же топике
- ✅ В #ДОСКА-ОБЪЯВЛЕНИЙ или #КУРИЛКА — бот игнорирует (quiet topic whitelist)

### F4. **DM staff Q&A (Phase 5.3)**
- В DM с ботом, БЕЗ команды: «Какие у меня задачи на завтра?»
- ✅ Бот отвечает с tool-call (list_my_open_tasks)
- ✅ Cross-check: BotCommandLog с `command='qna'`, `args` JSON

### F5. **Escalation classification**
- В qna: «Клиент требует скидку 20%, что делать?» (escalation kind)
- ✅ Бот: «🚨 Это нужно решать живьём — <manager> получил уведомление»
- ✅ Director получает DM с context

---

## 🟢 Группа G — Phase 6 digests

### G1. Morning digest (weekday 08:00 MSK)
- Cron `kpi_morning_digest` fires Mon-Fri 08:00
- ✅ Каждый assignable staff с `dm_chat_id` получает DM
- ✅ Структура: greeting (с именем) → ⚠️ Просрочки (если есть) → 📅 Сегодня →
  🎯 Активные лиды → ⏰ SLA-warnings (если есть) → 📊 Вчера
- ✅ Без задач: «📅 На сегодня задач нет. 🎯 Активных лидов нет.»
- Manual trigger: `Kpi::MorningDigestJob.new.perform`

### G2. Weekly report (Monday 10:00 MSK)
- Cron `kpi_weekly_report` Monday 10:00
- ✅ Managers + directors получают DM
- ✅ Структура: 📅 Header (Mon-Sun период dd.MM-dd.MM.yy) → 📊 Agency totals
  (tasks done/assigned + Δ%, on-time%, leads, first-contact-30min%, conversion%) →
  🏆 Top-3 medals → ⚠️ Bottom (overdue/suspicious) → 📈/📉 Trend vs prev week
- Manual trigger: `Kpi::WeeklyReportJob.new.perform`

### G3. Evening rollup (existing — Phase 7.6)
- `kpi_agency_digest` daily 18:00 → director DM с current-day summary
- ✅ Manual trigger возможен

---

## 🔴 Группа H — destructive / smoke с подчисткой

### H1. CRM webhook smoke (Phase 4E)
**Только если у Topnlab webhook реально настроен на наш endpoint!**
- Симулируем webhook через curl:
```bash
curl -X POST "https://victory62.org/webhooks/topnlab?key=$TOPNLAB_WEBHOOK_KEY" \
  -d "id=99999999&type=order" -i
```
- ✅ HTTP 200
- ✅ Redis `topnlab:last_webhook_at` updated
- ✅ TopnlabOrdersSyncJob + TopnlabCrmIntakeJob enqueued (Sidekiq UI)
- ✅ После 30s — Lead::Intake обработка (если order_id уже в БД)

### H2. Spam callback `[🚫 Спам]`
**На тестовом lead'е (созданном вручную).**
- Click [🚫 Спам] под якорной карточкой
- ✅ Карточка удаляется, lead становится `closed_lost`, metadata['spam_marked_by'] set
- ✅ Cross-check: `LeadEvent.find(<id>).current_stage == 'closed_lost'`

### H3. Cleanup test artifacts
```bash
docker compose exec -T web bin/rails runner '
test_lead_ids = LeadEvent.where("metadata->>\"name\" ILIKE ?", "%test%").pluck(:id)
DocumentRequirement.where(lead_event_id: test_lead_ids).destroy_all
Task.where(lead_event_id: test_lead_ids).destroy_all
LeadEvent.where(id: test_lead_ids).destroy_all
'
```

---

## Coverage matrix

| Feature | Sub-phase | Group |
|---|---|---|
| DocumentRequirement model + lifecycle | 4A | B1-B4 |
| `/doc` Tokenizer + Manager | 4B | B1-B4 |
| Builder + TemplateRegistry | 4C | B1 |
| Client TG-DM intake | 4D | C1-C3 |
| CRM webhook source | 4E | H1 |
| SLA ramping reminders | 4F | D1-D4 |
| AI document auto-match | 4G | B5 |
| Multi-channel attribution | 4H | C4 |
| document_checklist_status tool | 5.1 | F2 |
| Cross-topic @mention | 5.2 | F3 |
| DM staff Q&A | 5.3 | F4 |
| BotCommandLog QnA audit | 5.4 | F1, F4 |
| Morning digest | 6 | G1 |
| Weekly report | 6 | G2 |
| `/reassign` `/reopen` `/demote` `/deactivate` `/resume_batch` | 11 | E1-E5 |

## Notes

- **Quiet hours (21-07 MSK):** многие DM-flow skip ночью — тестировать в рабочее время
- **Weekend:** SLA reminders + morning digest skip Sat/Sun — для D/G groups планировать
  на Mon-Fri
- **Spam protection:** rate limit 10 msg/hour per tg_user_id (Phase 4D) — не bombard
- **Sidekiq UI:** `/sidekiq?token=$ADMIN_TOKEN` для observability cron jobs
- **Cleanup критичен:** test inquiries/leads НЕ должны попасть в production CRM
