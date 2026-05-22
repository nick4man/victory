# Director DM Control Panel — Phase 15

DM с @anvictorybot для роли director = полная панель управления АН. Не открываешь группу — всё в DM. Особенно полезно в дороге / на показах когда нужен быстрый снапшот или action.

## 4 pillars

### 1. READ — поиск и аудит

Свободно-формальные запросы текстом или голосом в DM. LLM сама выбирает нужный tool из Registry.

**Примеры запросов:**

```
«найди сообщения про Канищево за неделю»
→ search_group_messages(query='Канищево', period='this_week')

«что Ирина писала в #КВАРТИРЫ за вчера»
→ search_group_messages(sender_username='irina', topic='КВАРТИРЫ', period='yesterday')

«какие задачи overdue у всех»
→ search_all_tasks(only_overdue=true)

«задачи Маши на этой неделе»
→ search_all_tasks(assignee_username='masha', period='this_week')

«найди лиды по Солотче где сделки ещё не закрыли»
→ search_all_leads(query='Солотча', only_open=true)

«какие лиды на стадии показа»
→ search_all_leads(current_stage='show', only_open=true)

«какие задания я давала вчера»
→ director_self_audit(period='yesterday')  # self mode

«покажи всё что АН сделал на этой неделе»
→ director_self_audit(mode='agency_wide', period='this_week')

«кто топ-performer за месяц»
→ kpi_for(period='month')  # agency_wide возвращает top + bottom + anomalies
```

### 2. WRITE — управление лидами из DM

Все manager-команды теперь принимают `<lead_id>` как первый аргумент в DM (вместо reply-to-anchor):

| Команда | В group | В DM |
|---|---|---|
| /assign | reply на якорь + @user | `/assign 87 @irina` |
| /route | reply + topic | `/route 87 apartments` |
| /stage | reply + стадия | `/stage 87 показ` |
| /note | reply + текст | `/note 87 клиент готов к показу` |
| /close | reply + outcome | `/close 87 выиграно причина:цена` |
| /task | reply + dd.MM.yy + текст | `/task 87 15.05.26 позвонить Анне` |

Узнать lead_id — через search_all_leads или через `/dashboard` drill в Лиды.

### 3. PUSH — proactive notifications

**`director_daily_digest`** (08:30 MSK ежедневно):
- Леды/задачи за вчера
- Top performer
- SLA breach alerts
- Inline-кнопка [📊 Полный dashboard]

**`director_weekly_summary`** (понедельник 10:00 MSK):
- Цифры за неделю vs предыдущую (тренды ↑↓)
- Top-3 performers
- Overdue anomalies (>2σ от среднего)
- LLM cost report

Quiet hours (21:00–08:00 MSK) — digest пропускается.

### 4. PANEL — `/dashboard`

В DM: `/dashboard` или `/panel` → consolidated snapshot:

```
📊 Дашборд АН Виктори · 22.05.26 18:30 MSK

🎯 Лиды
  • Открытых: 12 (новых: 3, ждут first contact: 2)
  • Закрытых за 7 дней: 4 (won 3 / lost 1)
  • Overdue first_contact (>30 мин): 1 ⚠️

✅ Задачи
  • Открытых: 18 (overdue 3, due_today 5)
  • Завершено сегодня: 7
  • SLA breach (3+ дня overdue): 2 ⚠️

👥 Сотрудники (5 active)
  • @irina: 3 откр., 2 done, 0 overdue ✅
  • @sergey: 5 откр., 1 done, 1 overdue ⚠️
  …

📈 KPI неделя
  • Conversion: 38% (vs 32% ↑)
  • SLA on-time: 92% (vs 89% ↑)

🔔 Алерты (24ч)
  • Лид #87 — manager_pinged
  • Task #142 — SLA breach 4d

[🎯 Лиды] [✅ Задачи] [👥 Сотрудники] [🔍 Поиск]
[🔄 Обновить]
```

**Drill-down** — каждая inline-кнопка → edit_message_text с детализацией секции. [⬅️ Назад] возвращает к main.

---

## Архитектура

### Storage

`telegram_group_messages` (новая таблица, Phase 15):
- chat_id + tg_message_id + tg_thread_id + sender + body + sent_at
- `body_tsv` generated column с `to_tsvector('russian', body)` + GIN index
- Параллельная запись из `InboxSaver#persist_to_db` (soft-fail)
- Backfill из `/app/inbox/<date>/*.json`: `bundle exec rake telegram:backfill_group_messages`

`lead_events.search_tsv` (generated column):
- `to_tsvector('russian', metadata.summary + metadata.name + metadata.notes)`
- GIN index → FTS на лидах через `search_all_leads`

### Tools (chat_tools/staff/)

| Tool | Назначение | Phase |
|---|---|---|
| list_my_open_tasks | мои задачи | 7.5 |
| lookup_task | по id/title | 7.5 |
| lookup_lead | по id/name/phone | 7.5 |
| agent_status | nагрузка сотрудника | 7.5 |
| kpi_for | KPI snapshot (top/bottom/anomalies в Phase 15) | 7.6 |
| document_checklist_status | docs by lead | 5.1 |
| nextcloud_lookup_deal | папка сделки | 7.8 |
| nextcloud_list_templates | шаблоны договоров | 7.8 |
| director_self_audit | self (Iter 59) + agency_wide (Phase 15) | 59 |
| **search_group_messages** | FTS group msg | **15** |
| **search_all_tasks** | cross-staff tasks | **15** |
| **search_all_leads** | cross-staff leads + FTS | **15** |

### Security boundaries

- **Manager+** (manager/director/admin) видит все cross-staff данные
- **Agent** — silent self-only fallback (даже если LLM передал чужой username, возвращаем данные caller'а)
- Group messages — индексируем только `group`/`supergroup` (DM не пишем в БД — privacy)
- PII в результатах — manager+ access уже trusted (как при чтении group чата вживую)

---

## Setup / deploy

```bash
# 1. Накатить миграции
bundle exec rails db:migrate

# 2. Backfill existing inbox JSON в telegram_group_messages (one-shot)
bundle exec rake telegram:backfill_group_messages
# Опционально с даты:
bundle exec rake telegram:backfill_group_messages[2026-05-01]

# 3. Sidekiq автоматически подхватит новые cron jobs из sidekiq_cron.yml
#    (director_daily_digest, director_weekly_summary).
#    Если работают живой Sidekiq-процесс — restart:
docker restart victory-sidekiq-1

# 4. /dashboard sync в TG /-меню (manager+ tier):
# Если config/telegram_bot_commands.yml обновился — bundle exec rake telegram:sync_commands

# 5. Verify
bundle exec rspec spec/services/chat_tools/staff/search_*_spec.rb \
                  spec/services/telegram/work_bot/director_dashboard_spec.rb \
                  spec/services/telegram/work_bot/daily_digest_job_spec.rb
```

---

## Cheat-sheet для директора

В DM @anvictorybot можно (попробуй):

**Поиск**
- `найди сообщения про <название>` → search_group_messages
- `какие задачи overdue` → search_all_tasks
- `лиды по <район/имя>` → search_all_leads

**KPI**
- `топ-performer за <today/week/month>` → kpi_for
- `кто проседает по overdue` → kpi_for anomalies
- `что я давала за <today/yesterday/week>` → director_self_audit

**Action**
- `/dashboard` → полная панель
- `/assign 87 @irina` → назначить лид #87 Ирине
- `/route 87 apartments` → перенаправить в #КВАРТИРЫ
- `/stage 87 показ` → сменить стадию
- `/close 87 выиграно` → закрыть лид
- `/task 87 25.05.26 позвонить клиенту` → создать задачу
- `/note 87 клиент согласен на 8.2М` → заметка в CRM

**Photo** (Iter 60-61)
- Шли фото в DM → бот спросит: ☁️ облако / 📤 сотруднику / ✅ с задачей / ❌ отмена

**Voice** (Iter 59)
- Голосовое в DM → LLM сама определит: задача (передать сотруднику) или query (отчёт про себя)

---

## Roadmap (Phase B+)

- B.1 — Semantic search на pgvector (similar messages/leads)
- B.2 — LLM summarization conversation threads
- B.3 — Anomaly detection alerts (staff perf deviations)
- B.4 — Custom SQL queries через LLM tool-call с whitelisted schemas
- B.5 — Multi-director DM sync (один сделал — другой видит)
- B.6 — Mobile-optimized rich-cards
