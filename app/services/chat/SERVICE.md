# SERVICE.md — Чат-бот сайта (site chatbot)

- **owner**: victory
- **ported_from**: —
- **depends_on**: none (внутренний модуль Rails-приложения; лиды уходят в
  work_bot через контракт `Lead::Intake`, изоляция — через `Chat::TestMode`)
- **repatriate_by**: —

## Назначение

Публичный чат-виджет victory62.org (`app/views/shared/_chat_widget.html.erb`,
`Chat::ConversationsController` / `Chat::MessagesController`, LLM-ответы —
`Llm::ChatResponder` через `LlmReplyJob`, лиды — tool `ChatTools::QualifyLead`).
Боевые чаты (ДИСПЕТЧЕРСКАЯ и топики рабочей группы в Telegram) должны быть
совсем без тестовых сообщений (issue #227).

## Тест-изоляция лидов

Политика — `app/services/chat/test_mode.rb` (`Chat::TestMode`), по убыванию
надёжности:

1. **ENV-кран `SITE_CHATBOT_FORCE_TEST=1`** — ВСЕ site-лиды публикуются в
   тестовый чат (`TELEGRAM_TEST_CHAT_ID`), ДИСПЕТЧЕРСКАЯ не трогается вовсе.
   Ставится на прогоны, снимается перед боевым периодом. Единственная 100%-я
   гарантия. Дублируется на трёх уровнях: `Lead::Intake` (метадата LeadEvent),
   `ChatTools::QualifyLead` (метадата Inquiry → без CRM-синка и назначения
   агенту), `Conversation#lead_test_mode?` (thread-флаг в `LlmReplyJob`).
2. **Маршрутизация по `staff_test`** — `LeadAnnouncer#test_lead?` считает
   тестовым лид с `metadata['test']==true` ИЛИ `lead_ref.staff_test?` (Inquiry
   авто-помечена `StaffSubmissionDetector` по своим контактам сотрудника):
   карточка уходит в тестовый чат без явного флага в payload.
3. **Тумблер «🧪 Тест-прогон» в виджете** — переключатель в UI чата: включён
   → сессия под probe-`visitor_token` (`?visitor_token=probe-<name>` /
   `=off`), все лиды диалога с `metadata['test']=true`.
4. **Auto-test по происхождению** — сессии с не-прод хоста (staging,
   localhost; список — `SITE_CHATBOT_PROD_HOSTS`) или с IP из офисного пула
   (`SITE_CHATBOT_OFFICE_IPS`, comma-separated, точный IP или префикс
   подсети) автоматически тестовые: контроллеры ставят флаг
   `metadata['auto_test']` на Conversation, он не снимается обратно.

### Честное ограничение

Против прогона «как реальный клиент» с чужими контактами с прод-домена без
крана и тумблера защиты нет и не будет — любая эвристика рискует заблокировать
реального клиента (неприемлемо). Полную гарантию даёт только кран п.1.
