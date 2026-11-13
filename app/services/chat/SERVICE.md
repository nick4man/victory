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

1. **ENV-кран `SITE_CHATBOT_FORCE_TEST=1`** — ВСЕ лиды чат-бота (записи с
   `Inquiry source='site_chatbot'`) публикуются в тестовый чат
   (`TELEGRAM_TEST_CHAT_ID`), ДИСПЕТЧЕРСКАЯ не трогается вовсе. Ставится на
   прогоны, снимается перед боевым периодом. Единственная 100%-я гарантия.
   Дублируется на трёх уровнях: `Lead::Intake` (метадата LeadEvent),
   `ChatTools::QualifyLead` (метадата Inquiry → без CRM-синка и назначения
   агенту), `Conversation#lead_test_mode?` (thread-флаг в `LlmReplyJob`).
   Контроллеры фиксируют кран sticky-флагом `metadata['force_test']` на
   Conversation (rev #230, round 3): кран, снятый между приёмом сообщения
   и фоновыми задачами, диалог обратно боевым не делает. Обычные боевые
   формы сайта (`ContactFormsController`,
   `PropertyValuationsController` идут теми же `site_*` источниками) краном
   не задеваются (rev #230). Без `TELEGRAM_TEST_CHAT_ID` тест-эскалации и
   PDF тест-лидов пропускаются (fail-closed) — в рабочую группу не идут.
2. **Маршрутизация по `staff_test`** — `LeadAnnouncer#test_lead?` считает
   тестовым лид с `metadata['test']==true` ИЛИ `staff_test` по сильному
   правилу детектора (`StaffSubmissionDetector.hard_isolation?`: слабое
   `name_staff_first` — совпадение только по имени — боевой маршрут не
   меняет, иначе реальный клиент «Надежда» потерял бы карточку; rev #230).
   Карточка уходит в тестовый чат без явного флага в payload. Сотрудник с
   записью `User` (role agent/admin) и своими контактами без флага/крана
   по-прежнему получает staff-skip (тишина, #214) — для автоматической
   тестовой карточки ему нужен тумблер/кран.
3. **Тумблер «🧪 Тест-прогон» в виджете** — переключатель в UI чата:
   включён → POST `/chat/conversation/test_mode` (same-origin + CSRF) —
   сервер мятит свежий HMAC probe-токен и ставит signed-куку, все лиды
   нового диалога с `metadata['test']=true`. Токен из URL/JSON виджет не
   получает и не передаёт (rev #230, round 4): публичная выдача HMAC-токена
   позволила бы любому анониму переключить чужую сессию в тест-контур на
   90 дней и разделить с жертвой один Conversation. URL-вход со
   staff-токеном из консоли (`VisitorIdentity.probe_token`,
   `?visitor_token=probe-<name>-<16hex>`) остаётся для ссылок сотрудникам.
   В JSON сессии два флага: `test_probe` (ручной тумблер) и `test_mode`
   (полный режим, включая auto-test/кран).
4. **Auto-test по происхождению** — сессии с не-прод хоста (staging,
   localhost; список — `SITE_CHATBOT_PROD_HOSTS`) или с IP из офисного пула
   (`SITE_CHATBOT_OFFICE_IPS`, comma-separated, точный IP или префикс
   подсети) автоматически тестовые: контроллеры ставят флаг
   `metadata['auto_test']` на Conversation, он не снимается обратно.
   Origin/Referer тоже учитываются (rev #230): запрос на боевой endpoint
   с дев/стейджинг заголовком (localhost, приватный IP, поддомен боевого
   домена) — тестовый. Внешний Referer боевого клиента (поисковики,
   агрегаторы) сессию тестовой НЕ делает.

### Честное ограничение

Против прогона «как реальный клиент» с чужими контактами с прод-домена без
крана и тумблера защиты нет и не будет — любая эвристика рискует заблокировать
реального клиента (неприемлемо). Полную гарантию даёт только кран п.1.
