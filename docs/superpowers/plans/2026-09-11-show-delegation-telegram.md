# Делегирование показов через Telegram — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Дать агентству двухнедельную базовую линию по показам (стадия, сегмент покупателя, отчёт о показе с возражениями, обратная связь собственнику, недельная сводка по сегментам и объектам) целиком внутри рабочего Telegram-бота, и подготовить — но не включать — фильтр «кто едет на показ».

**Architecture:** Всё строится на уже существующих примитивах work-bot: `LeadEvent` получает `segment`, `property_id`, `first_show_at`, `contract_at`; появляется модель `ShowReport` (один показ = одна запись), которая заполняется по шаблону «LLM-извлечение → превью с кнопками → запись» (как `TaskBatch`). Голосовое агента после показа расшифровывает `VoiceTranscriber`, `ShowReports::Extractor` раскладывает возражения и черновик сообщения собственнику, `ShowReports::Finalizer` двигает стадию, ставит `Task` «обратная связь до 11:00» и предлагает отправить сообщение собственнику. Недельная сводка директора (`WeeklySummaryJob`) получает блок `Kpi::ShowFunnel` — конверсия показ→договор **внутри сегмента** и метрики по объектам. Фильтр `ShowRouting` едет тёмным за `ENV['SHOW_ROUTING_ENABLED']`.

**Tech Stack:** Rails 8.1.3.1 / Ruby 3.4.10 / PostgreSQL 15 (`db/structure.sql`), Sidekiq + sidekiq-cron, Telegram Bot API через `Telegram::Client`, Groq Whisper (`VoiceTranscriber`), `Llm::OmniClient` цепочка `:staff_analysis`, RSpec + WebMock.

**Spec:** `.claude/docs/reglament/BOTTLENECK.md` (решения), контекст — `.claude/docs/reglament/DESIGN.md`, `step-04-inbound-shows.md` + `-review.md` (I2–I5), `TESTING.md`.

**Сверено с разбором telegram-кода 10.09.26** («Как пользователи говорят с системой через Telegram», четыре параллельных агента по ветке на 10.09.26). Сверка 12.09.26: план совместим с диспетчером, но в нём нашлись две поломки стыковки (Task 2, Step 5) и четыре находки разбора, которые план обязан закрыть, потому что сам же на них встаёт — Task 0A, Task 0B, Task 4 Step 4, Task 7 Step 5, Task 8 Step 7.

## Global Constraints

- **Worktree:** код пишется в новом worktree `~/victory-shows` на ветке `claude/show-delegation` (`git -C ~/victory worktree add ~/victory-shows -b claude/show-delegation main`). `~/victory` — live-prod bind-mount, там только этот документ; чужие worktree read-only.
- **Ruby только через `bin/rb`:** `bin/rb --db bundle exec rspec <path>`, `bin/rb bundle exec rubocop <paths>`. Не докладывать «зелёное», не прогнав там, где есть Ruby. Перед первым прогоном `bin/rb --seed-bundle` и `bin/rb --db bin/rails db:prepare`.
- **Стек PR:** три стека по правилам `gh-stack` (CLAUDE.md): A «данные+сегмент+стадии» → B «отчёт о показе» → C «фильтр (dark)». Каждый PR ≤ ~500 строк, ревью `/code-review <PR#>` обязательно после зелёного CI.
- Каждый `.rb` — `# frozen_string_literal: true`, одинарные кавычки, комментарии по-русски с пометкой **«BOTTLENECK»** и причиной (почему), не что.
- Enum'ы — только `prefix: true` с русским переводом в комментарии (`ShowReport`). `LeadEvent` enum'ов не использует — новые поля `segment` идут строкой + `validates :inclusion` + frozen-константа, как `STAGES`.
- Даты в сообщениях — `dd.MM.yy` через `Formatters::DateFormat.fmt` / `.fmt_dt`, время — `Europe/Moscow`.
- Soft-delete (`deleted_at` + `default_scope { not_deleted }`) — на `ShowReport` обязателен. `lead_events` soft-delete не добавлять.
- `db/structure.sql` не править руками — регенерируется `bin/rb --db bin/rails db:migrate`. Миграции `ActiveRecord::Migration[8.1]`, с русским комментарием-«почему» над классом.
- Любая новая метрика по лидам — через `LeadEvent.real` (исключая `staff_test`).
- Telegram: `parse_mode: 'HTML'` по умолчанию → экранировать пользовательский текст (`escape_html` в командах, локальный `escape` в остальном). `callback_data` — ASCII, ≤ 64 байт, аргументы без `:`. Каждый путь callback'а заканчивается `ack(...)`. Не использовать `Telegram::Client#edit_message_reply_markup` (сломан kwargs-хвостом) — снимать клавиатуру через `edit_message_text(..., reply_markup: { inline_keyboard: [] })`.
- Новая команда регистрируется в **трёх** местах: `Router::COMMANDS`, `config/telegram_bot_commands.yml`, `Commands::Help::ENTRIES`.
- LLM: только `chain: :staff_analysis`, `response_format: { type: 'json_object' }`, парсинг в `rescue JSON::ParserError`, никаких платных моделей первыми. В БД персистить только `transcript_redacted` (`Privacy::TranscriptRedactor`), raw-текст — лишь в LLM.
- Метрики сравнивать **только внутри сегмента**; KPI — по объектам и стадиям, а не рейтинг людей (BOTTLENECK «Как мерить»). Текст сводки обязан это напоминать.
- `ENV['SHOW_ROUTING_ENABLED']` не включать до завершения базовой линии (2 недели **и** ≥ 20 подтверждённых `ShowReport`); решение — у руководителя, не у исполнителя плана.
- Коммит после каждой задачи; трейлер `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- **`Result` — это `Struct`, а не `Hash`.** `Lead::Intake::Result`, `VoiceTranscriber::Result` и все `Result` этого плана — `Struct.new(..., keyword_init: true)`. Никогда не писать `result.is_a?(Hash)`: ровно такая проверка против Struct'а молча отключала подтверждение заявки клиенту (лид создавался, карточка публиковалась, клиенту не уходило ничего), и спека это пропускала, потому что стабила `Lead::Intake` литеральным хэшем. В спеках стабить настоящий `Result`.
- **Каждая новая текстовая команда пишет `BotCommandLog`.** Callback'и логирует `CallbacksRouter` сам (`log_audit`), текстовые команды — не логирует никто, хотя комментарий в модели обещает «unified bot-action stream». Для базовой линии это не косметика: `/segment`, `/stage`, `/show` — ручные отметки, по которым оценивают людей, а BOTTLENECK прямо требует прослеживаемости ручного ввода (там же — `suspicious_flag` на `Task`). Делается один раз в `Commands::Base` (Task 0B), поэтому в самих командах ничего писать не надо.
- **Всё, что уходит клиенту или собственнику, уважает `Telegram::WorkBot::QuietHours`** (21:00–07:00 MSK; `active?`, `defer_until`, как в `Sla::PingJob` и `DocumentReminderJob`). Показы вечерние, отчёт часто в 21:30 — сообщение собственнику в этот момент недопустимо. Ответ сотруднику на его собственное действие тихие часы не нарушает и не откладывается.
- **Изменения в диспетчере и реестрах команд закрываются спекой.** Порядок веток в `Telegram::InboundProcessor` — фактическая спецификация приоритетов, и до сверки он не был зафиксирован ни одним тестом (нет спек ни на `InboundProcessor`, ни на `Router`, ни на `CallbacksRouter`, ни request-спеки на `Webhooks::TelegramController`). План меняет гейт голосовой ветки и добавляет записи в три реестра команд — значит обязан оставить после себя тест (Task 8, Step 7).

## File Structure

**Стек A — данные, сегмент, стадии**

| Файл | Ответственность |
|---|---|
| `db/migrate/20260911100000_add_show_funnel_fields_to_lead_events.rb` | `segment`, `property_id`, `first_show_at`, `contract_at` + бэкфилл `property_id` |
| `app/models/lead_event.rb` | `SEGMENTS`, `SEGMENT_LABELS`, `belongs_to :property`, `has_many :show_reports`, скоупы |
| `app/services/lead/property_resolver.rb` | единственное место «lead_ref → Property» |
| `app/services/lead/intake.rb` | проставляет `property_id` при создании лида; гейт «вернувшийся клиент → существующая карточка, без второго `LeadEvent`» (Task 0A) |
| `app/services/telegram/work_bot/lead_stage_transition.rb` | ставит `first_show_at` / `contract_at` при переходе |
| `app/services/telegram/work_bot/segment_keyboard.rb` | одна клавиатура сегментов для карточки, нуджа и отчёта |
| `app/services/telegram/work_bot/callbacks/segment_callback.rb` | `segment:<lead_id>:<value>` |
| `app/services/telegram/work_bot/callbacks/stage_callback.rb` | `stage:<lead_id>:show|contract` |
| `app/services/telegram/work_bot/commands/segment.rb` | `/segment` текстом из DM |
| `app/services/telegram/work_bot/commands/stage.rb` | нудж «укажи сегмент» после `/stage показ` |
| `app/services/telegram/work_bot/lead_announcer.rb` | бейдж сегмента, ряд кнопок сегмента и стадий, счётчик показов; `keyboard_for_card(topic_key)` — один источник клавиатуры для публикации, переезда карточки и `refresh!` |
| `app/services/telegram/work_bot/commands/base.rb` | `BotCommandLog` на каждую текстовую команду — один раз для всех 25 существующих и 5 новых (Task 0B) |
| `app/services/telegram/work_bot/router.rb` | регистрация новых команд; клиент без строки в `telegram_users` не получает подсказку про `/whoami` (Task 0B) |

**Стек B — отчёт о показе**

| Файл | Ответственность |
|---|---|
| `db/migrate/20260911100100_create_show_reports.rb`, `app/models/show_report.rb` | факт показа: кто показывал, исход, возражения, черновик собственнику |
| `app/services/telegram/work_bot/show_reports/extractor.rb` | LLM: транскрипт → JSON (лид, исход, возражения, цена, сообщение собственнику) |
| `app/services/telegram/work_bot/show_reports/intake.rb` | общая точка входа voice/`/show`: извлечь → создать pending → превью |
| `app/services/telegram/work_bot/show_reports/confirmer.rb` | превью в DM с кнопками |
| `app/services/telegram/work_bot/show_reports/finalizer.rb` | подтверждение: стадия, задача до 11:00, пост в топик, черновик собственнику |
| `app/services/telegram/work_bot/callbacks/show_report_callback.rb` | `show_report:<id>:approve|cancel|toggle_conductor|owner_push|owner_sent` |
| `app/services/telegram/work_bot/commands/show.rb` | `/show <lead_id> <текст>` — текстовый вход |
| `app/services/telegram/work_bot/voice_intent_branch.rb`, `voice_intake_processor.rb` | третий интент `show_report`; голос агента = только отчёт о показе |
| `app/services/telegram/work_bot/commands/objections.rb` | `/objections` — сводка возражений по объекту |
| `app/services/kpi/show_funnel.rb` | сегмент × кто показывал, метрики по объектам, показы без отчёта |
| `app/services/telegram/work_bot/weekly_summary_job.rb` | блок воронки показов в понедельничной сводке |

**Стек C — фильтр (dark)**

| Файл | Ответственность |
|---|---|
| `app/services/telegram/work_bot/show_routing.rb` | рекомендация «агент / руководитель» по сегменту и истории |
| `app/services/telegram/work_bot/callbacks/show_assign_callback.rb` | `show_assign:<lead_id>:<tg_user_id>` — назначить показывающего |
| `app/services/telegram/work_bot/commands/bargain.rb` | `/bargain` — торг на объекте: мгновенный DM руководителю с карточкой |

Регистрация: `router.rb`, `callbacks_router.rb`, `commands/help.rb`, `config/telegram_bot_commands.yml`. Спеки зеркалят пути под `spec/`.

---

## Стек A — данные, сегмент, стадии

> Task 0A и Task 0B идут **до** Task 1: обе чинят то, на что базовая линия опирается, и обе ломают её молча. Ревью каждой — отдельное, PR — общий со стеком A.

### Task 0A: Вернувшийся клиент не создаёт вторую карточку

Находка разбора 10.09.26. `TgDmSource` при cross-channel match (тот же телефон / `tg_user_id` / email) дописывает сообщение в `metadata['client_history']` существующей карточки и возвращает пару `[inquiry, metadata]` с `returning_client: true`. Комментарий в адаптере обещает «append к existing thread без duplicate LeadEvent», но обещание ничем не исполняется: `Lead::Intake#call` на любой непустой ответ адаптера делает `LeadEvent.create!` и вызывает `LeadAnnouncer`.

Почему это блокирует базовую линию, а не просто раздражает: состояние расползается по двум карточкам. Сегмент ставят кнопкой на одной, показ записывают на другой, `first_show_at` и `contract_at` оказываются на разных строках — и лид попадает в матрицу «сегмент × кто показывал» как «не указан». Это порча ровно той оси, ради которой собирается база.

**Files:**
- Modify: `app/services/lead/intake.rb` (`#call`, сразу после `ref, metadata = result`)
- Test: `spec/services/lead/intake_spec.rb` (новый `describe` в конце файла, перед закрывающим `end`)

**Interfaces:**
- Produces: при `metadata['returning_client'] == true` и существующем `LeadEvent` на том же `lead_ref` — `Lead::Intake::Result#lead_event` возвращает **существующую** запись, `LeadEvent.count` не меняется, `LeadAnnouncer` не вызывается, `Result#success?` остаётся `true`. Во всех остальных случаях поведение не меняется.

- [ ] **Step 1: Спека (красная)**

В `spec/services/lead/intake_spec.rb` добавить перед последним `end` файла:

```ruby
  describe 'вернувшийся клиент (cross-channel match)' do
    let(:inquiry) { create(:inquiry, source: 'tg_dm') }
    let!(:existing) do
      LeadEvent.create!(lead_ref: inquiry, source: 'tg_dm', current_stage: 'first_contact',
                        anchor_topic_key: 'apartments', tg_chat_id: -100_123, anchor_message_id: 9001)
    end

    before do
      allow_any_instance_of(Lead::Intake::TgDmSource)
        .to receive(:call)
        .and_return([inquiry, { 'returning_client' => true, 'channel' => 'tg_dm' }])
    end

    it 'не создаёт второй LeadEvent и возвращает существующий' do
      result = nil
      expect {
        result = described_class.call(source: 'tg_dm', payload: { text: 'ещё вопрос' },
                                     announcer: fake_announcer_class)
      }.not_to change(LeadEvent, :count)

      expect(result).to be_success
      expect(result.lead_event).to eq(existing)
    end

    it 'не публикует вторую карточку' do
      described_class.call(source: 'tg_dm', payload: { text: 'ещё вопрос' },
                           announcer: fake_announcer_class)
      expect(fake_announcer_class.last).to be_nil
    end

    it 'без существующей карточки ведёт себя как раньше — создаёт запись' do
      existing.destroy!
      expect {
        described_class.call(source: 'tg_dm', payload: { text: 'первый раз' },
                             announcer: fake_announcer_class)
      }.to change(LeadEvent, :count).by(1)
    end
  end
```

`fake_announcer_class` уже есть в файле (`let` в самом верху, `reset!` в `before`) — не переопределять. `after_create_commit :push_to_work_bot` у `Inquiry` в транзакционной спеке не срабатывает, поэтому `create(:inquiry)` лишнего `LeadEvent` не порождает.

- [ ] **Step 2: Прогнать — должна упасть**

Run: `bin/rb --db bundle exec rspec spec/services/lead/intake_spec.rb -e 'вернувшийся клиент'`
Expected: FAIL — первый пример падает на `expected LeadEvent.count not to have changed, but did change by 1`.

- [ ] **Step 3: Гейт в `Lead::Intake#call`**

В `app/services/lead/intake.rb` после строки `ref, metadata = result` вставить:

```ruby
      # BOTTLENECK — вернувшийся клиент дописывается в существующую карточку,
      # а не плодит вторую. TgDmSource при cross-channel match уже дописал
      # сообщение в metadata['client_history'] существующего LeadEvent и вернул
      # returning_client: true; до этого гейта Intake всё равно создавал новую
      # запись и публиковал второй анкор. Две карточки на одного клиента — это
      # не только шум в диспетчерской: сегмент ставят на одной, показ пишут на
      # другой, и лид уходит в матрицу «сегмент × кто показывал» как «не указан».
      if metadata.is_a?(Hash) && metadata['returning_client'] == true
        existing = LeadEvent.where(lead_ref_type: ref.class.name, lead_ref_id: ref.id)
                            .order(created_at: :desc).first
        if existing
          Rails.logger.info(
            "[Lead::Intake] #{@source} returning client → append to lead##{existing.id}, no new LeadEvent"
          )
          return Result.new(success: true, lead_event: existing, error: nil)
        end
      end
```

- [ ] **Step 4: Прогнать — зелёная**

Run: `bin/rb --db bundle exec rspec spec/services/lead/intake_spec.rb`
Expected: PASS, все примеры файла (новые 3 + старые 4).

- [ ] **Step 5: Регресс по соседям и линт**

Run: `bin/rb --db bundle exec rspec spec/services/lead spec/services/telegram/client_bot`
Expected: PASS. Если падает что-то про «вторую карточку» — это спека, которая фиксировала старое поведение; переписать на новое, а не откатывать гейт.
Run: `bin/rb bundle exec rubocop app/services/lead/intake.rb spec/services/lead/intake_spec.rb`

- [ ] **Step 6: Коммит**

```bash
git add app/services/lead/intake.rb spec/services/lead/intake_spec.rb
git commit -m "fix(leads): вернувшийся клиент дописывается в существующую карточку, а не создаёт вторую

Адаптер обещал append без duplicate LeadEvent, Intake создавал запись на любой
непустой ответ. Из-за этого сегмент и показ оказывались на разных карточках —
база для эксперимента по показам становилась неинтерпретируемой.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 0B: Аудит текстовых команд и служебные подсказки мимо клиента

Две находки разбора, обе становятся значимыми именно из-за этого плана.

Первая: `BotCommandLog` пишут только `CallbacksRouter`, два варианта `/whoami` и `StaffChatResponder`. Ни одна из 25 текстовых команд не логируется. План добавляет пять — `/segment`, `/stage`, `/show`, `/objections`, `/bargain` — и это ровно те ручные отметки, по которым будут оценивать людей. Получается асимметрия: сегмент, поставленный кнопкой, в аудите есть, тот же сегмент командой — нет.

Вторая: нераспознанная команда отвечает `Доступно: /whoami email` кому угодно, включая клиента, который промахнулся мимо `/start`. Заодно `cmd` интерполируется в HTML без экранирования — `/<b` от клиента даёт 400 от Telegram и молчание вместо ответа.

Проверено отдельно и **не подтвердилось**: `/help` каталог команд сотрудников клиенту не показывает — `Commands::Help#handle` выводит только секцию `:public`, а незарегистрированному добавляет подсказку про привязку. Править там нечего.

**Files:**
- Modify: `app/services/telegram/work_bot/commands/base.rb` (`#call` → `#dispatch` + `#audit!`)
- Modify: `app/services/telegram/work_bot/router.rb` (ветка `else` в `dispatch`, ~строка 94)
- Test: `spec/services/telegram/work_bot/commands/base_spec.rb` (новый), `spec/services/telegram/work_bot/router_spec.rb` (новый — см. также Task 8, Step 9)

**Interfaces:**
- Produces: `BotCommandLog` на каждый вызов любой команды-наследника `Commands::Base` — `command` = `self.class.name.demodulize.underscore` (`'segment'`, `'show'`), `result` = символ исхода (`'handled'`, `'denied_not_staff'`, `'denied_manager'`, `'denied_director'`, `'error'`), `args` — обрезанные до 500 символов аргументы, при исключении `error_class` + `error_message`. `Router#dispatch` для отправителя без `TelegramUser` возвращает `:client_hint` вместо `:unknown_command`.

- [ ] **Step 1: Спека базы команд (красная)**

```ruby
# spec/services/telegram/work_bot/commands/base_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Commands::Base do
  let(:tg_client) { instance_double(Telegram::Client, send_message: { 'message_id' => 1 }) }
  let(:msg) { { 'from' => { 'id' => 555 }, 'chat' => { 'id' => 555, 'type' => 'private' }, 'message_id' => 7 } }
  let(:agent) do
    TelegramUser.create!(tg_user_id: 555, role: 'agent', first_name: 'A',
                         is_manager: false, status: 'active', dm_chat_id: 555)
  end

  # Минимальная команда-наследник: не хочется привязывать спеку базы
  # к поведению конкретной команды.
  let(:ok_command) do
    Class.new(described_class) do
      def self.name = 'Telegram::WorkBot::Commands::FakeOk'
      def handle = :handled
    end
  end

  let(:boom_command) do
    Class.new(described_class) do
      def self.name = 'Telegram::WorkBot::Commands::FakeBoom'
      def handle = raise(StandardError, 'boom')
    end
  end

  it 'пишет BotCommandLog на успешный вызов' do
    expect {
      ok_command.new(message: msg, args: 'нал', tg_user: agent, client: tg_client).call
    }.to change(BotCommandLog, :count).by(1)

    log = BotCommandLog.order(:created_at).last
    expect(log.tg_user_id).to eq(555)
    expect(log.command).to eq('fake_ok')
    expect(log.args).to eq('нал')
    expect(log.result).to eq('handled')
  end

  it 'пишет отказ, а не тишину, когда отправителя нет в telegram_users' do
    klass = Class.new(described_class) do
      def self.name = 'Telegram::WorkBot::Commands::FakeManager'
      manager_only
      def handle = :handled
    end

    klass.new(message: msg, args: '', tg_user: nil, client: tg_client).call
    expect(BotCommandLog.order(:created_at).last.result).to eq('denied_not_staff')
  end

  it 'пишет отказ по роли' do
    klass = Class.new(described_class) do
      def self.name = 'Telegram::WorkBot::Commands::FakeManager2'
      manager_only
      def handle = :handled
    end

    klass.new(message: msg, args: '', tg_user: agent, client: tg_client).call
    expect(BotCommandLog.order(:created_at).last.result).to eq('denied_manager')
  end

  it 'пишет error_class и error_message при исключении' do
    boom_command.new(message: msg, args: '', tg_user: agent, client: tg_client).call
    log = BotCommandLog.order(:created_at).last
    expect(log.result).to eq('error')
    expect(log.error_class).to eq('StandardError')
    expect(log.error_message).to eq('boom')
  end

  it 'падение аудита не ломает команду' do
    allow(BotCommandLog).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, 'db down')
    expect(ok_command.new(message: msg, args: '', tg_user: agent, client: tg_client).call).to eq(:handled)
  end
end
```

- [ ] **Step 2: Прогнать — должна упасть**

Run: `bin/rb --db bundle exec rspec spec/services/telegram/work_bot/commands/base_spec.rb`
Expected: FAIL — `expected BotCommandLog.count to have changed by 1, but was changed by 0`.

- [ ] **Step 3: Аудит в `Commands::Base`**

Заменить `#call` целиком:

```ruby
        def call
          outcome = dispatch
          audit!(outcome)
          outcome
        rescue StandardError => e
          Rails.logger.error("[WorkBot::Command #{self.class.name}] #{e.class}: #{e.message}")
          audit!(:error, error_class: e.class.name, error_message: e.message)
          reply("⚠️ Ошибка: #{e.message}")
          :error
        end
```

и добавить в приватную секцию в конце класса (если `private` ещё не объявлен — объявить после последнего `protected`-метода):

```ruby
        # Гейты вынесены из #call, чтобы исход был символом, а не возвратом
        # reply (тот отдаёт хэш ответа Telegram — в result его писать нельзя).
        def dispatch
          return handle if self.class.public_command?

          if tg_user.nil?
            reply('🚫 Команда доступна только сотрудникам АН. Свяжитесь с руководителем.')
            return :denied_not_staff
          end

          # Phase 13 Iter 41 — manager_or_director? включает legacy is_manager +
          # директоров + admin. До фикса /assign блокировался для директора с
          # role=director, is_manager=false.
          if self.class.manager_only? && !tg_user.manager_or_director?
            reply('🚫 Команда доступна только руководителям.')
            return :denied_manager
          end

          if self.class.director_only? && !tg_user.can_voice_distribute?
            reply('🚫 Только для директора АН. Используй /task @username dd.MM.yy <текст> для одиночной задачи.')
            return :denied_director
          end

          handle
        end

        # BOTTLENECK — до этого места текстовые команды не попадали в
        # BotCommandLog вообще: писали только CallbacksRouter, два варианта
        # /whoami и StaffChatResponder, хотя комментарий в модели обещает
        # «unified bot-action stream». Для базовой линии показов это критично:
        # /segment, /stage и /show — ручные отметки, по которым оценивают людей,
        # а BOTTLENECK требует, чтобы ручной ввод был прослеживаем (там же —
        # suspicious_flag на Task). Аудит здесь, а не в каждой команде, чтобы
        # новая команда получала его по факту наследования.
        def audit!(outcome, error_class: nil, error_message: nil)
          tg_user_id = @message.is_a?(Hash) ? @message.dig('from', 'id') : nil
          return if tg_user_id.blank?

          BotCommandLog.create!(
            tg_user_id:    tg_user_id,
            command:       self.class.name.to_s.demodulize.underscore,
            args:          @args.to_s.truncate(500),
            result:        outcome.is_a?(Symbol) ? outcome.to_s : 'handled',
            error_class:   error_class,
            error_message: error_message.to_s.presence&.truncate(500)
          )
        rescue StandardError => e
          Rails.logger.warn("[WorkBot::Commands::Base#audit!] #{e.class}: #{e.message}")
        end
```

- [ ] **Step 4: Прогнать базу и весь каталог команд**

Run: `bin/rb --db bundle exec rspec spec/services/telegram/work_bot/commands/base_spec.rb`
Expected: PASS (5 примеров)
Run: `bin/rb --db bundle exec rspec spec/services/telegram/work_bot`
Expected: PASS. Спеки, которые проверяли текст отказа, не затронуты — тексты сохранены дословно. Если какая-то спека сравнивала возврат `call` с хэшем ответа Telegram, поправить её на символ исхода: это и есть смысл правки.

- [ ] **Step 5: Спека роутера (красная)**

```ruby
# spec/services/telegram/work_bot/router_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Router do
  let(:sent) { [] }
  let(:tg_client) do
    client = instance_double(Telegram::Client)
    allow(client).to receive(:send_message) { |text, **_| sent << text; { 'message_id' => 1 } }
    client
  end

  def dispatch(text, from_id:)
    msg = { 'from' => { 'id' => from_id }, 'chat' => { 'id' => from_id, 'type' => 'private' },
            'message_id' => 11, 'text' => text }
    described_class.new(msg, client: tg_client).call
  end

  it 'клиенту (нет строки в telegram_users) не показывает подсказку про /whoami' do
    expect(dispatch('/квартира', from_id: 999)).to eq(:client_hint)
    expect(sent.join).not_to include('/whoami')
  end

  it 'сотруднику на нераспознанную команду отвечает как раньше' do
    TelegramUser.create!(tg_user_id: 777, role: 'agent', first_name: 'A',
                         is_manager: false, status: 'active', dm_chat_id: 777)
    expect(dispatch('/нетакой', from_id: 777)).to eq(:unknown_command)
    expect(sent.join).to include('/whoami')
  end

  it 'экранирует команду в ответе — /<b от клиента не роняет sendMessage' do
    TelegramUser.create!(tg_user_id: 778, role: 'agent', first_name: 'B',
                         is_manager: false, status: 'active', dm_chat_id: 778)
    dispatch('/<b', from_id: 778)
    expect(sent.join).to include('&lt;b')
    expect(sent.join).not_to include('<b</code>')
  end
end
```

- [ ] **Step 6: Прогнать — должна упасть**

Run: `bin/rb --db bundle exec rspec spec/services/telegram/work_bot/router_spec.rb`
Expected: FAIL — первый пример получает `:unknown_command` и текст с `/whoami`.

- [ ] **Step 7: Ветка `else` в `Router#dispatch`**

Заменить:

```ruby
        else
          reply("Команда #{cmd} не распознана либо ещё не реализована. Доступно: <code>/whoami email</code>")
          :unknown_command
        end
```

на:

```ruby
        else
          # BOTTLENECK — каталог служебных подсказок не уходит тому, кого нет в
          # telegram_users. Клиент, промахнувшийся мимо /start, получал
          # инструкцию «Доступно: /whoami email» — приглашение в рабочий бот.
          # После этого плана в каталоге на пять команд больше, так что цена
          # утечки растёт. Экранирование cmd — из той же ветки: parse_mode HTML
          # на `/<b` отдаёт 400 и клиент не получает ничего.
          if TelegramUser.find_by(tg_user_id: @msg.dig('from', 'id')).nil?
            reply('Я бот агентства «Виктори». Напишите запрос обычным сообщением — или пришлите фото документа, и менеджер свяжется с вами.')
            return :client_hint
          end

          reply("Команда #{escape(cmd)} не распознана либо ещё не реализована. Доступно: <code>/whoami email</code>")
          :unknown_command
        end
```

- [ ] **Step 8: Прогнать и закоммитить**

Run: `bin/rb --db bundle exec rspec spec/services/telegram/work_bot/router_spec.rb spec/services/telegram/work_bot/commands`
Expected: PASS
Run: `bin/rb bundle exec rubocop app/services/telegram/work_bot/commands/base.rb app/services/telegram/work_bot/router.rb spec/services/telegram/work_bot/commands/base_spec.rb spec/services/telegram/work_bot/router_spec.rb`

```bash
git add app/services/telegram/work_bot/commands/base.rb app/services/telegram/work_bot/router.rb \
        spec/services/telegram/work_bot/commands/base_spec.rb spec/services/telegram/work_bot/router_spec.rb
git commit -m "feat(bot): BotCommandLog на текстовые команды; служебные подсказки не уходят клиенту

Аудит писали только callback-роутер и /whoami — отметка кнопкой попадала в лог,
та же отметка командой нет. Для базовой линии показов ручной ввод должен быть
прослеживаем. Плюс: нераспознанная команда больше не предлагает клиенту /whoami,
и cmd экранируется (parse_mode HTML падал на /<b).

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 1: Поля воронки показов на `lead_events` + резолвер объекта

**Files:**
- Create: `db/migrate/20260911100000_add_show_funnel_fields_to_lead_events.rb`
- Create: `app/services/lead/property_resolver.rb`
- Modify: `app/models/lead_event.rb` (константы после `TOPIC_KEYS`, ассоциации после `belongs_to :routed_by`, валидация, скоупы)
- Modify: `app/services/lead/intake.rb:54-61` (атрибуты `LeadEvent.create!`)
- Modify: `app/services/telegram/work_bot/lead_stage_transition.rb` (`apply_local!`, строки ~95-100)
- Test: `spec/services/lead/property_resolver_spec.rb`, `spec/models/lead_event_spec.rb` (дополнить), `spec/services/telegram/work_bot/lead_stage_transition_spec.rb` (новый)

**Interfaces:**
- Produces: `LeadEvent::SEGMENTS = %w[cash mortgage_approved mortgage_pending alternative cold]`, `LeadEvent::SEGMENT_LABELS` (Hash value→«эмодзи текст»), `LeadEvent#segment` (String|nil), `LeadEvent#property` (Property|nil), `LeadEvent#first_show_at`, `LeadEvent#contract_at`, `LeadEvent.segmented`, `LeadEvent.shown`; `Lead::PropertyResolver.for_ref(lead_ref) -> Property|nil`, `Lead::PropertyResolver.call(lead_event) -> Property|nil`.

- [ ] **Step 1: Спека резолвера (красная)**

```ruby
# spec/services/lead/property_resolver_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Lead::PropertyResolver do
  let(:property) { create(:property) }

  it 'Property как lead_ref → сам объект' do
    expect(described_class.for_ref(property)).to eq(property)
  end

  it 'Inquiry с property_id → объект заявки' do
    inquiry = create(:inquiry, property_id: property.id)
    expect(described_class.for_ref(inquiry)).to eq(property)
  end

  it 'Inquiry без property_id → nil' do
    expect(described_class.for_ref(create(:inquiry))).to be_nil
  end

  it 'ref без property_id (PropertyValuation) → nil, не падает' do
    ref = PropertyValuation.new
    expect(described_class.for_ref(ref)).to be_nil
  end

  it 'nil → nil' do
    expect(described_class.for_ref(nil)).to be_nil
  end

  it 'удалённый объект (deleted_at) всё равно резолвится — история показов не должна терять объект' do
    property.update_column(:deleted_at, Time.current)
    inquiry = create(:inquiry, property_id: property.id)
    expect(described_class.for_ref(inquiry)&.id).to eq(property.id)
  end
end
```

- [ ] **Step 2: Запустить — убедиться, что падает**

Run: `bin/rb --db bundle exec rspec spec/services/lead/property_resolver_spec.rb`
Expected: FAIL — `uninitialized constant Lead::PropertyResolver`

- [ ] **Step 3: Резолвер**

```ruby
# app/services/lead/property_resolver.rb
# frozen_string_literal: true

module Lead
  # BOTTLENECK — единственное место, где лид превращается в объект.
  #
  # lead_ref полиморфный (Inquiry / Property / PropertyValuation / BuyerOrder),
  # и до этого каждый потребитель (LeadStageTransition#resolve_seller_user,
  # TaskBatchConfirmer#nc_link_for) резолвил объект по-своему. Для метрик
  # «по объектам, а не по людям» нужен один ответ на вопрос «какой объект
  # показывали», поэтому логика вынесена сюда, а результат денормализуется в
  # lead_events.property_id (см. миграцию 20260911100000).
  #
  # unscoped — осознанно: объект мог уйти в архив/soft-delete после показа,
  # а история показов по нему должна остаться привязанной.
  class PropertyResolver
    def self.for_ref(ref)
      return nil if ref.nil?
      return ref if ref.is_a?(::Property)
      return nil unless ref.respond_to?(:property_id) && ref.property_id.present?

      ::Property.unscoped.find_by(id: ref.property_id)
    end

    def self.call(lead_event)
      return lead_event.property if lead_event.property_id.present?

      for_ref(lead_event.lead_ref)
    end
  end
end
```

- [ ] **Step 4: Прогнать спеку резолвера**

Run: `bin/rb --db bundle exec rspec spec/services/lead/property_resolver_spec.rb`
Expected: PASS (6 examples). Если `create(:inquiry, property_id:)` падает на валидации — посмотреть `Inquiry` и передать `property: property` вместо id.

- [ ] **Step 5: Миграция**

```ruby
# db/migrate/20260911100000_add_show_funnel_fields_to_lead_events.rb
# frozen_string_literal: true

# BOTTLENECK — базовая линия эксперимента «агент показывает, руководитель торгуется».
#
# segment       — квалификация покупателя, которую агент и так выясняет по Шагу 4,
#                 но которую негде было сохранить; без неё сравнение конверсий
#                 между агентом и руководителем — selection bias в чистом виде.
# property_id   — денормализация lead_ref → Property: метрики считаются по объектам,
#                 а полиморфный join по трём формам ref'а не индексируется.
# first_show_at — момент первого показа (ставится при переходе в стадию show
#                 и/или подтверждении ShowReport), ключ когорты.
# contract_at   — момент перехода в contract; конверсия показ→договор считается
#                 по этим двум датам, а не по чтению stage_history из jsonb.
class AddShowFunnelFieldsToLeadEvents < ActiveRecord::Migration[8.1]
  def up
    change_table :lead_events, bulk: true do |t|
      t.string    :segment, limit: 32          # cash | mortgage_approved | mortgage_pending | alternative | cold
      t.references :property, foreign_key: true, null: true, index: true
      t.datetime  :first_show_at
      t.datetime  :contract_at
    end
    add_index :lead_events, :segment
    add_index :lead_events, :first_show_at
    add_index :lead_events, %i[property_id current_stage]

    # Бэкфилл property_id из двух форм ref'а, которые знают объект.
    # PropertyValuation и BuyerOrder объекта не имеют — остаются NULL.
    execute <<~SQL.squish
      UPDATE lead_events SET property_id = lead_ref_id
      WHERE lead_ref_type = 'Property' AND property_id IS NULL
        AND EXISTS (SELECT 1 FROM properties p WHERE p.id = lead_events.lead_ref_id)
    SQL
    execute <<~SQL.squish
      UPDATE lead_events le SET property_id = i.property_id
      FROM inquiries i
      WHERE le.lead_ref_type = 'Inquiry' AND le.lead_ref_id = i.id
        AND le.property_id IS NULL AND i.property_id IS NOT NULL
        AND EXISTS (SELECT 1 FROM properties p WHERE p.id = i.property_id)
    SQL
    # Бэкфилл дат из stage_history: первое появление 'to'=>'show' / 'contract'.
    execute <<~SQL.squish
      UPDATE lead_events le SET first_show_at = sub.at
      FROM (
        SELECT id, MIN((e->>'at')::timestamp) AS at
        FROM lead_events, jsonb_array_elements(COALESCE(metadata->'stage_history', '[]'::jsonb)) e
        WHERE e->>'to' = 'show' GROUP BY id
      ) sub
      WHERE le.id = sub.id AND le.first_show_at IS NULL
    SQL
    execute <<~SQL.squish
      UPDATE lead_events le SET contract_at = sub.at
      FROM (
        SELECT id, MIN((e->>'at')::timestamp) AS at
        FROM lead_events, jsonb_array_elements(COALESCE(metadata->'stage_history', '[]'::jsonb)) e
        WHERE e->>'to' = 'contract' GROUP BY id
      ) sub
      WHERE le.id = sub.id AND le.contract_at IS NULL
    SQL
  end

  def down
    remove_index :lead_events, %i[property_id current_stage]
    remove_index :lead_events, :first_show_at
    remove_index :lead_events, :segment
    remove_reference :lead_events, :property, foreign_key: true
    remove_column :lead_events, :contract_at
    remove_column :lead_events, :first_show_at
    remove_column :lead_events, :segment
  end
end
```

- [ ] **Step 6: Применить миграцию**

Run: `bin/rb --db bin/rails db:migrate && git diff --stat db/structure.sql`
Expected: в `db/structure.sql` появились 4 колонки, 4 индекса, FK `lead_events.property_id → properties`. Если diff содержит посторонние схемы (`tiger`, `topology`) — это утечка локальной БД, откатить лишние строки (прецедент PR #16).

- [ ] **Step 7: Спеки модели (красные)** — добавить в `spec/models/lead_event_spec.rb` внутри `RSpec.describe LeadEvent do`:

```ruby
  describe 'segment (BOTTLENECK)' do
    it 'принимает только значения из SEGMENTS' do
      expect(build_event(segment: 'cash')).to be_valid
      expect(build_event(segment: 'vip')).not_to be_valid
    end

    it 'nil допустим — сегмент выясняется позже' do
      expect(build_event(segment: nil)).to be_valid
    end

    it 'SEGMENT_LABELS покрывает каждый сегмент' do
      expect(LeadEvent::SEGMENT_LABELS.keys).to match_array(LeadEvent::SEGMENTS)
    end

    it '#segment_label для nil — «не указан»' do
      expect(build_event(segment: nil).segment_label).to include('не указан')
    end
  end

  describe 'scopes воронки показов' do
    let!(:shown)   { build_event(first_show_at: 1.day.ago).tap(&:save!) }
    let!(:unshown) { build_event.tap(&:save!) }

    it '.shown — только с first_show_at' do
      expect(described_class.shown).to contain_exactly(shown)
    end

    it '.segmented — только с сегментом' do
      shown.update!(segment: 'cold')
      expect(described_class.segmented).to contain_exactly(shown)
    end
  end
```

- [ ] **Step 8: Модель** — в `app/models/lead_event.rb`:

После `TOPIC_KEYS` добавить:

```ruby
  # BOTTLENECK — квалификация покупателя. Единственный критерий фильтра
  # «кто едет на показ», и единственный ключ, внутри которого можно сравнивать
  # конверсию агента и руководителя (см. reglament/BOTTLENECK.md «Как мерить»).
  SEGMENTS = ['cash', 'mortgage_approved', 'mortgage_pending', 'alternative', 'cold'].freeze
  SEGMENT_LABELS = {
    'cash'              => '💵 Наличные',
    'mortgage_approved' => '🏦 Ипотека одобрена',
    'mortgage_pending'  => '⏳ Ипотека не одобрена',
    'alternative'       => '🔄 Альтернатива (продаёт своё)',
    'cold'              => '❄️ Холодный'
  }.freeze
  SEGMENT_UNKNOWN_LABEL = '❔ сегмент не указан'
```

После `belongs_to :routed_by, ...`:

```ruby
  # BOTTLENECK — денормализованный объект (Lead::PropertyResolver).
  # has_many :show_reports объявляется вместе с самой моделью (Task 4): связь,
  # объявленная раньше таблицы, роняет любой destroy лида на NameError.
  belongs_to :property, optional: true
```

⚠️ `has_many :show_reports` здесь **не объявляем**, хотя соблазн есть. Поймано на исполнении 12.09.26: ActiveRecord резолвит класс ассоциации лениво, поэтому объявление живёт тихо до первого `LeadEvent#destroy` — и тогда падает `NameError: Missing model class ShowReport`. Между Task 1 и Task 4 это ловится спекой Task 0A (`existing.destroy!`). Связь добавляется в Task 4, Step 3, вместе с моделью.

После `validates :tg_chat_id, presence: true`:

```ruby
  validates :segment, inclusion: { in: SEGMENTS }, allow_nil: true
```

После `scope :staff_test_only`:

```ruby
  # BOTTLENECK — воронка показов.
  scope :shown,     -> { where.not(first_show_at: nil) }
  scope :segmented, -> { where.not(segment: nil) }
```

После `def assigned?`:

```ruby
  def segment_label
    SEGMENT_LABELS[segment] || SEGMENT_UNKNOWN_LABEL
  end
```

- [ ] **Step 9: Прогнать спеки модели**

Run: `bin/rb --db bundle exec rspec spec/models/lead_event_spec.rb`
Expected: PASS

- [ ] **Step 10: Проставлять объект при создании лида** — в `app/services/lead/intake.rb`, в вызове `LeadEvent.create!` (строки ~54-61) добавить атрибут:

```ruby
        property:         Lead::PropertyResolver.for_ref(ref),
```

Локальная переменная в `#call` называется `ref` (`ref, metadata = result`), а не `lead_ref` — `lead_ref:` это имя атрибута. Поймано на исполнении 12.09.26.

- [ ] **Step 11: Даты переходов** — в `app/services/telegram/work_bot/lead_stage_transition.rb#apply_local!` рядом с `attrs[:first_contact_at] = ...`:

```ruby
        # BOTTLENECK — ключи когорты для Kpi::ShowFunnel. Ставятся один раз:
        # /unstage намеренно не сбрасывает (история), как и first_contact_at.
        attrs[:first_show_at] = Time.current if @new == 'show' && @lead.first_show_at.nil?
        attrs[:contract_at]   = Time.current if @new == 'contract' && @lead.contract_at.nil?
```

- [ ] **Step 12: Спека перехода (новый файл)**

```ruby
# spec/services/telegram/work_bot/lead_stage_transition_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::LeadStageTransition do
  let(:tg_client) do
    instance_double(Telegram::Client, send_message: { 'message_id' => 1 }, edit_message_text: { 'message_id' => 1 })
  end
  let(:agent) { TelegramUser.create!(tg_user_id: 501, role: 'agent', first_name: 'A', is_manager: false, status: 'active') }
  let(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'tg_dm', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1, anchor_message_id: 10, assigned_to: agent)
  end

  def transition(to)
    described_class.new(lead, to, actor: agent, client: tg_client).call
  end

  it '→ show ставит first_show_at один раз' do
    expect(transition('show')).to be_success
    first = lead.reload.first_show_at
    expect(first).to be_present

    described_class.new(lead, 'first_contact', actor: agent, client: tg_client).call
    transition('show')
    expect(lead.reload.first_show_at).to eq(first)
  end

  it '→ contract ставит contract_at' do
    transition('show')
    transition('contract')
    expect(lead.reload.contract_at).to be_present
  end

  it '→ first_contact не трогает first_show_at' do
    transition('first_contact')
    expect(lead.reload.first_show_at).to be_nil
  end
end
```

Run: `bin/rb --db bundle exec rspec spec/services/telegram/work_bot/lead_stage_transition_spec.rb`
Expected: PASS. Если `→ contract` пытается постить в #СДЕЛКА — `send_message` уже задвоен; если лезет в Topnlab — у `Inquiry` нет `crm_id`, `push_stage_to_crm` пропускается.

- [ ] **Step 13: Линтер и коммит**

```bash
bin/rb bundle exec rubocop app/models/lead_event.rb app/services/lead app/services/telegram/work_bot/lead_stage_transition.rb spec/services/lead spec/models/lead_event_spec.rb spec/services/telegram/work_bot/lead_stage_transition_spec.rb
git add db/migrate/20260911100000_add_show_funnel_fields_to_lead_events.rb db/structure.sql app/models/lead_event.rb app/services/lead/property_resolver.rb app/services/lead/intake.rb app/services/telegram/work_bot/lead_stage_transition.rb spec/
git commit -m "feat(leads): segment, property_id, first_show_at, contract_at — база под воронку показов (BOTTLENECK)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Сегмент покупателя одной кнопкой — клавиатура, callback, команда, бейдж

**Files:**
- Create: `app/services/telegram/work_bot/segment_keyboard.rb`
- Create: `app/services/telegram/work_bot/callbacks/segment_callback.rb`
- Create: `app/services/telegram/work_bot/commands/segment.rb`
- Modify: `app/services/telegram/work_bot/lead_announcer.rb` (`format_card_text` бейдж-строка ~111-134; `routing_keyboard_for` ~195-208)
- Modify: `app/services/telegram/work_bot/callbacks_router.rb:20-40` (`PREFIX_MAP`), `app/services/telegram/work_bot/router.rb:21-54` (`COMMANDS`), `app/services/telegram/work_bot/commands/help.rb:15-68` (`ENTRIES`), `config/telegram_bot_commands.yml`
- Test: `spec/services/telegram/work_bot/segment_keyboard_spec.rb`, `spec/services/telegram/work_bot/callbacks/segment_callback_spec.rb`, `spec/services/telegram/work_bot/commands/segment_spec.rb`

**Interfaces:**
- Consumes: `LeadEvent::SEGMENTS`, `SEGMENT_LABELS`, `#segment_label` (Task 1); `Callbacks::Base#ack/#lead_event/#client/#tg_user/#args`; `Commands::Base#resolve_lead!/#reply/#assignee_or_manager?`.
- Produces: `Telegram::WorkBot::SegmentKeyboard.for(lead) -> { inline_keyboard: [...] }` (одна строка из 5 кнопок `segment:<lead_id>:<value>`), `SegmentKeyboard.row(lead) -> Array<Hash>` (ряд для встраивания в другую клавиатуру), `SegmentKeyboard.prompt_text -> String`; `Commands::Segment::SEGMENT_MAP` (русские синонимы → значение).

- [ ] **Step 1: Спека клавиатуры (красная)**

```ruby
# spec/services/telegram/work_bot/segment_keyboard_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::SegmentKeyboard do
  let(:lead) { LeadEvent.new(id: 42) }

  it 'один ряд — по кнопке на каждый сегмент' do
    row = described_class.row(lead)
    expect(row.size).to eq(LeadEvent::SEGMENTS.size)
    expect(row.map { |b| b[:callback_data] }).to all(match(/\Asegment:42:[a-z_]+\z/))
  end

  it 'callback_data укладывается в лимит Telegram 64 байта' do
    described_class.row(lead).each { |b| expect(b[:callback_data].bytesize).to be <= 64 }
  end

  it '.for оборачивает ряд в inline_keyboard' do
    expect(described_class.for(lead)).to eq(inline_keyboard: [described_class.row(lead)])
  end
end
```

- [ ] **Step 2: Клавиатура**

```ruby
# app/services/telegram/work_bot/segment_keyboard.rb
# frozen_string_literal: true

module Telegram
  module WorkBot
    # BOTTLENECK — единственная клавиатура выбора сегмента покупателя.
    # Используется в трёх местах (карточка лида, нудж после /stage показ,
    # подтверждение отчёта о показе), поэтому живёт отдельно: разъедутся
    # подписи — разъедутся и данные.
    class SegmentKeyboard
      # Короткие подписи — в ряду пять кнопок, длинные Telegram режет.
      SHORT = {
        'cash'              => '💵 Нал',
        'mortgage_approved' => '🏦 Ипотека ✓',
        'mortgage_pending'  => '⏳ Ипотека ?',
        'alternative'       => '🔄 Альт',
        'cold'              => '❄️ Холод'
      }.freeze

      def self.row(lead)
        LeadEvent::SEGMENTS.map do |value|
          { text: SHORT.fetch(value), callback_data: "segment:#{lead.id}:#{value}" }
        end
      end

      def self.for(lead)
        { inline_keyboard: [row(lead)] }
      end

      def self.prompt_text
        '❔ <b>Укажи сегмент покупателя</b> — это то, что ты и так выясняешь по Шагу 4. ' \
          'Без сегмента показ не попадёт в сравнение конверсий.'
      end
    end
  end
end
```

Run: `bin/rb --db bundle exec rspec spec/services/telegram/work_bot/segment_keyboard_spec.rb` → PASS

- [ ] **Step 3: Спека callback'а (красная)**

```ruby
# spec/services/telegram/work_bot/callbacks/segment_callback_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Callbacks::SegmentCallback do
  let(:tg_client) do
    instance_double(Telegram::Client,
                    edit_message_text: { 'message_id' => 9000 },
                    answer_callback_query: { 'ok' => true })
  end
  let(:agent)  { TelegramUser.create!(tg_user_id: 111, role: 'agent', first_name: 'A', is_manager: false, status: 'active') }
  let(:other)  { TelegramUser.create!(tg_user_id: 222, role: 'agent', first_name: 'B', is_manager: false, status: 'active') }
  let(:director) do
    TelegramUser.create!(tg_user_id: 333, role: 'director', first_name: 'O', is_manager: false, status: 'active')
  end
  let!(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'tg_dm', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_123, anchor_message_id: 9000, assigned_to: agent)
  end

  def run(data, user: agent)
    cb = { 'id' => 'cb-1', 'data' => data, 'from' => { 'id' => user.tg_user_id },
           'message' => { 'message_id' => 9000, 'chat' => { 'id' => -100_123, 'type' => 'supergroup' } } }
    described_class.new(callback_query: cb, tg_user: user, args: data.split(':').drop(1), client: tg_client).call
  end

  it 'assignee ставит сегмент и карточка перерисовывается' do
    run("segment:#{lead.id}:cash")
    expect(lead.reload.segment).to eq('cash')
    expect(tg_client).to have_received(:edit_message_text)
      .with(a_string_including('💵 Наличные'), hash_including(chat_id: -100_123, message_id: 9000))
    expect(tg_client).to have_received(:answer_callback_query).with('cb-1', hash_including(text: a_string_including('Наличные')))
  end

  it 'директор без is_manager тоже может (gotcha: manager_only в Callbacks::Base смотрит только is_manager)' do
    run("segment:#{lead.id}:cold", user: director)
    expect(lead.reload.segment).to eq('cold')
  end

  it 'чужой агент получает alert и ничего не меняет' do
    run("segment:#{lead.id}:cold", user: other)
    expect(lead.reload.segment).to be_nil
    expect(tg_client).to have_received(:answer_callback_query).with('cb-1', hash_including(show_alert: true))
  end

  it 'неизвестное значение → alert' do
    run("segment:#{lead.id}:vip")
    expect(lead.reload.segment).to be_nil
    expect(tg_client).to have_received(:answer_callback_query).with('cb-1', hash_including(show_alert: true))
  end

  it 'повторное нажатие того же сегмента — не ошибка, карточку не трогает' do
    lead.update!(segment: 'cash')
    run("segment:#{lead.id}:cash")
    expect(tg_client).not_to have_received(:edit_message_text)
    expect(tg_client).to have_received(:answer_callback_query).with('cb-1', hash_including(text: a_string_including('Уже')))
  end
end
```

- [ ] **Step 4: Callback**

```ruby
# app/services/telegram/work_bot/callbacks/segment_callback.rb
# frozen_string_literal: true

module Telegram
  module WorkBot
    module Callbacks
      # BOTTLENECK — кнопка сегмента под карточкой лида.
      # callback_data: "segment:<lead_event_id>:<value>", value ∈ LeadEvent::SEGMENTS.
      #
      # Не manager_only: сегмент выясняет тот, кто ведёт переписку, то есть
      # assignee. Проверку делаем сами, а не макросом — manager_only в
      # Callbacks::Base смотрит is_manager? и отсекает директора без флага
      # (в Commands::Base тот же гейт уже починен на manager_or_director?).
      class SegmentCallback < Base
        def handle
          value = @args[1].to_s
          return ack("⚠️ Неизвестный сегмент: #{value}", alert: true) unless LeadEvent::SEGMENTS.include?(value)

          lead = lead_event
          return ack('🚫 Сегмент ставит assignee лида или руководитель', alert: true) unless authorized?(lead)
          return ack("ℹ️ Уже #{lead.segment_label}") if lead.segment == value

          lead.with_lock do
            lead.reload
            history = lead.append_history(key: 'segment_history',
                                          entry: { 'at' => Time.current.iso8601, 'from' => lead.segment,
                                                   'to' => value, 'by' => actor_mention })
            lead.update!(segment: value, metadata: lead.metadata.merge('segment_history' => history))
          end
          refresh_card(lead)
          ack("✅ #{lead.segment_label}")
        end

        private

        def authorized?(lead)
          return false if tg_user.nil?

          lead.assigned_to_id == tg_user.id || tg_user.manager_or_director?
        end

        def refresh_card(lead)
          return if lead.anchor_message_id.blank?

          text = LeadAnnouncer.new(lead, client: client).format_card_text
          client.edit_message_text(text, chat_id: lead.tg_chat_id, message_id: lead.anchor_message_id,
                                         parse_mode: 'HTML',
                                         reply_markup: LeadAnnouncer.new(lead, client: client).keyboard_for_card)
        rescue Telegram::Client::Error => e
          Rails.logger.warn("[SegmentCallback] card refresh failed: #{e.message}")
        end
      end
    end
  end
end
```

- [ ] **Step 5: Карточка лида** — в `app/services/telegram/work_bot/lead_announcer.rb`:

В `format_card_text`, сразу после формирования `badge_line` (≈ строка 134), добавить отдельную строку сегмента:

```ruby
        # BOTTLENECK — сегмент всегда виден: пустой сегмент должен раздражать.
        lines << @lead.segment_label
```

Добавить публичный метод рядом с `routing_keyboard_for`. **Топик — обязательный параметр, а не `@lead.anchor_topic_key`**: см. обоснование сразу под кодом.

```ruby
      # Клавиатура для перерисовки карточки из callback'ов (segment/stage/show_report).
      # Маршрутизация и «Назначить/Спам» — как при публикации; плюс ряд сегментов,
      # пока он не выбран, и ряд стадий, пока лид открыт.
      #
      # BOTTLENECK — topic_key приходит параметром, а не читается из
      # @lead.anchor_topic_key. AnchorMigrator при переезде карточки в
      # спец-топик вызывает repost_to(target) ДО того, как обновит
      # anchor_topic_key в базе: на момент отрисовки лид ещё «в диспетчерской».
      # Прочитали бы из модели — ряд кнопок маршрутизации уехал бы в #КВАРТИРЫ
      # вместе с карточкой, и лид можно было бы маршрутизировать повторно.
      def keyboard_for_card(topic_key = @lead.anchor_topic_key)
        rows = routing_keyboard_for(topic_key)[:inline_keyboard]
        rows << SegmentKeyboard.row(@lead) if @lead.segment.blank?
        rows << stage_row if @lead.open?
        { inline_keyboard: rows }
      end

      private

      def stage_row
        [
          { text: '📅 Показ',   callback_data: "stage:#{@lead.id}:show" },
          { text: '✍️ Договор', callback_data: "stage:#{@lead.id}:contract" }
        ]
      end
```

Дальше — **три** места вызова, не одно. Пропустить любое из них означает, что ряды сегмента и стадий молча исчезнут с карточки в самый неподходящий момент:

1. `#send_card(topic_key)` — публикация и переезд: `reply_markup: routing_keyboard_for(topic_key)` → `reply_markup: keyboard_for_card(topic_key)`. Через этот же метод работает `#repost_to`, то есть `AnchorMigrator`.
2. `.refresh!` (начало файла, ~строка 23) — `reply_markup: announcer.send(:routing_keyboard_for, topic_key)` → `reply_markup: announcer.keyboard_for_card(topic_key)`. Этот путь вызывает `PropertyValuationJob` после расчёта оценки: без правки успешный расчёт стирает кнопки сегмента и стадий с карточки, и сотруднику остаётся только команда. Заодно поправить комментарий над методом — он обещает «Кнопки routing остаются».
3. Callback'и `segment` / `stage` / `show_report`, которые перерисовывают карточку, — вызывают `keyboard_for_card` без аргумента (лид уже в своём топике, база актуальна).

Если `private` уже объявлен ниже в файле — поставить `stage_row` в существующую приватную секцию.

- [ ] **Step 5a: Спека на клавиатуру при переезде карточки**

В `spec/services/telegram/work_bot/segment_keyboard_spec.rb` (или рядом, в спеке announcer'а, если она появится) добавить:

```ruby
  it 'карточка, переехавшая в спец-топик, не уносит с собой кнопки маршрутизации' do
    lead = LeadEvent.create!(lead_ref: create(:inquiry), source: 'tg_dm', current_stage: 'new',
                             anchor_topic_key: 'dispatcher', tg_chat_id: -100_123)
    markup = Telegram::WorkBot::LeadAnnouncer.new(lead).keyboard_for_card('apartments')
    data = markup[:inline_keyboard].flatten.map { |b| b[:callback_data] }

    expect(data).to include("segment:#{lead.id}:cash")
    expect(data.grep(/\Aroute:/)).to be_empty
  end
```

Run: `bin/rb --db bundle exec rspec spec/services/telegram/work_bot/segment_keyboard_spec.rb`
Expected: PASS

- [ ] **Step 6: Прогнать callback-спеку**

Run: `bin/rb --db bundle exec rspec spec/services/telegram/work_bot/callbacks/segment_callback_spec.rb`
Expected: PASS

- [ ] **Step 7: Спека команды (красная)**

```ruby
# spec/services/telegram/work_bot/commands/segment_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Commands::Segment do
  let(:tg_client) do
    instance_double(Telegram::Client, send_message: { 'message_id' => 1 }, edit_message_text: { 'message_id' => 1 })
  end
  let(:agent) { TelegramUser.create!(tg_user_id: 111, role: 'agent', first_name: 'A', is_manager: false, status: 'active', dm_chat_id: 111) }
  let!(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'tg_dm', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_123, anchor_message_id: 9000, assigned_to: agent)
  end

  def run(args, msg_overrides = {})
    msg = { 'chat' => { 'id' => 111, 'type' => 'private' }, 'from' => { 'id' => 111 }, 'message_id' => 5,
            'text' => "/segment #{args}" }.merge(msg_overrides)
    described_class.new(message: msg, args: args, tg_user: agent, client: tg_client).send(:handle)
  end

  it '/segment <id> ипотека одобрена — ставит mortgage_approved' do
    run("#{lead.id} ипотека одобрена")
    expect(lead.reload.segment).to eq('mortgage_approved')
    expect(tg_client).to have_received(:send_message).with(a_string_including('🏦 Ипотека одобрена'), anything)
  end

  it 'reply на карточку в группе работает без id' do
    run('наличные', 'chat' => { 'id' => -100_123, 'type' => 'supergroup' }, 'reply_to_message' => { 'message_id' => 9000 })
    expect(lead.reload.segment).to eq('cash')
  end

  it 'без аргумента — показывает клавиатуру выбора, сегмент не меняет' do
    run(lead.id.to_s)
    expect(lead.reload.segment).to be_nil
    expect(tg_client).to have_received(:send_message)
      .with(a_string_including('сегмент'), hash_including(reply_markup: hash_including(:inline_keyboard)))
  end

  it 'неизвестное слово — подсказка со списком' do
    run("#{lead.id} богатый")
    expect(lead.reload.segment).to be_nil
    expect(tg_client).to have_received(:send_message).with(a_string_including('Доступно'), anything)
  end
end
```

- [ ] **Step 8: Команда**

```ruby
# app/services/telegram/work_bot/commands/segment.rb
# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # BOTTLENECK — `/segment <значение>` reply на карточку или `/segment <lead_id> <значение>` в DM.
      # Дублёр кнопок SegmentKeyboard для тех, кому привычнее текст.
      # Без значения — присылает клавиатуру.
      class Segment < Base
        SEGMENT_MAP = {
          'наличные'            => 'cash',
          'нал'                 => 'cash',
          'кэш'                 => 'cash',
          'ипотека одобрена'    => 'mortgage_approved',
          'ипотека+'            => 'mortgage_approved',
          'одобрена'            => 'mortgage_approved',
          'ипотека не одобрена' => 'mortgage_pending',
          'ипотека?'            => 'mortgage_pending',
          'ипотека'             => 'mortgage_pending',
          'альтернатива'        => 'alternative',
          'альт'                => 'alternative',
          'холодный'            => 'cold',
          'холод'               => 'cold'
        }.freeze

        def handle
          lead = resolve_lead!
          return reply(lead_not_found_hint('segment наличные')) unless lead

          word = @args.to_s.strip.downcase
          if word.blank?
            return reply("#{SegmentKeyboard.prompt_text}\nСейчас: #{lead.segment_label}",
                         reply_markup: SegmentKeyboard.for(lead))
          end

          value = SEGMENT_MAP[word]
          return reply("Не понял сегмент. Доступно: <code>#{SEGMENT_MAP.keys.join(', ')}</code>") unless value
          return reply("🚫 Сегмент ставит assignee (#{lead.assigned_to&.mention || 'не назначен'}) или руководитель.") unless assignee_or_manager?(lead)

          lead.update!(segment: value)
          reply("Лид ##{lead.id}: #{lead.segment_label} ✅")
        end
      end
    end
  end
end
```

`Commands::Base#reply(text, **opts)` пробрасывает `opts` в `send_message` — проверить, что `reply_markup:` проходит (в `base.rb:73-80` opts читаются через `opts.fetch(:parse_mode, ...)`; если `reply_markup` не пробрасывается — добавить `reply_markup: opts[:reply_markup]` в вызов).

- [ ] **Step 9: Регистрация**

`app/services/telegram/work_bot/router.rb` `COMMANDS` — добавить `'/segment' => Commands::Segment,`.
`app/services/telegram/work_bot/callbacks_router.rb` `PREFIX_MAP` — добавить `'segment' => 'Telegram::WorkBot::Callbacks::SegmentCallback',` и `'stage' => 'Telegram::WorkBot::Callbacks::StageCallback',` (класс — в Task 3).
`config/telegram_bot_commands.yml` в секцию Staff:

```yaml
  - { cmd: segment,      tier: staff,    group: true,  desc: 'Сегмент покупателя: /segment наличные (reply на карточку)' }
```

`app/services/telegram/work_bot/commands/help.rb` `ENTRIES` — строка по образцу соседних: `/segment` — «Сегмент покупателя (наличные / ипотека одобрена / ипотека не одобрена / альтернатива / холодный)».

- [ ] **Step 10: Прогнать всё по задаче + линтер**

```bash
bin/rb --db bundle exec rspec spec/services/telegram/work_bot/commands/segment_spec.rb spec/services/telegram/work_bot/callbacks/segment_callback_spec.rb spec/services/telegram/work_bot/segment_keyboard_spec.rb spec/services/telegram/work_bot/commands_menu_sync_spec.rb
bin/rb bundle exec rubocop app/services/telegram/work_bot config/telegram_bot_commands.yml
```
Expected: PASS; rubocop без оффенс (следить за `Metrics/MethodLength` 25 строк в `handle`).

- [ ] **Step 11: Коммит**

```bash
git add app/services/telegram/work_bot config/telegram_bot_commands.yml spec/services/telegram/work_bot
git commit -m "feat(work_bot): сегмент покупателя одной кнопкой — SegmentKeyboard, callback, /segment, бейдж на карточке

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Стадия одной кнопкой + нудж про сегмент

**Files:**
- Create: `app/services/telegram/work_bot/callbacks/stage_callback.rb`
- Modify: `app/services/telegram/work_bot/commands/stage.rb` (после успешного перехода)
- Test: `spec/services/telegram/work_bot/callbacks/stage_callback_spec.rb`, `spec/services/telegram/work_bot/commands/stage_spec.rb` (новый)

**Interfaces:**
- Consumes: `LeadStageTransition.new(lead, stage, actor:, client:).call -> result(success?, prev_stage, new_stage, message)`; `SegmentKeyboard.for/prompt_text` (Task 2); `LeadAnnouncer#format_card_text/#keyboard_for_card`.
- Produces: callback `stage:<lead_id>:show|contract`; поведение: после перехода в `show` при пустом сегменте бот присылает `SegmentKeyboard` (в топик карточки или в DM).

- [ ] **Step 1: Спека callback'а (красная)**

```ruby
# spec/services/telegram/work_bot/callbacks/stage_callback_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Callbacks::StageCallback do
  let(:tg_client) do
    instance_double(Telegram::Client,
                    send_message: { 'message_id' => 77 },
                    edit_message_text: { 'message_id' => 9000 },
                    answer_callback_query: { 'ok' => true })
  end
  let(:agent) { TelegramUser.create!(tg_user_id: 111, role: 'agent', first_name: 'A', is_manager: false, status: 'active') }
  let!(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'tg_dm', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_123, anchor_thread_id: 17,
                      anchor_message_id: 9000, assigned_to: agent)
  end

  def run(data, user: agent)
    cb = { 'id' => 'cb-1', 'data' => data, 'from' => { 'id' => user.tg_user_id },
           'message' => { 'message_id' => 9000, 'message_thread_id' => 17,
                          'chat' => { 'id' => -100_123, 'type' => 'supergroup' } } }
    described_class.new(callback_query: cb, tg_user: user, args: data.split(':').drop(1), client: tg_client).call
  end

  it '📅 Показ → стадия show, first_show_at, и нудж про сегмент в тот же топик' do
    run("stage:#{lead.id}:show")
    lead.reload
    expect(lead.current_stage).to eq('show')
    expect(lead.first_show_at).to be_present
    expect(tg_client).to have_received(:send_message).with(
      a_string_including('сегмент'),
      hash_including(chat_id: -100_123, message_thread_id: 17, reply_markup: hash_including(:inline_keyboard))
    )
  end

  it 'нуджа нет, если сегмент уже указан' do
    lead.update!(segment: 'cash')
    run("stage:#{lead.id}:show")
    expect(tg_client).not_to have_received(:send_message).with(a_string_including('сегмент'), anything)
  end

  it '✍️ Договор → contract + contract_at' do
    run("stage:#{lead.id}:contract")
    expect(lead.reload.current_stage).to eq('contract')
    expect(lead.contract_at).to be_present
  end

  it 'стадия вне разрешённых кнопок → alert' do
    run("stage:#{lead.id}:closed_won")
    expect(lead.reload.current_stage).to eq('first_contact')
    expect(tg_client).to have_received(:answer_callback_query).with('cb-1', hash_including(show_alert: true))
  end

  it 'чужой агент → alert' do
    other = TelegramUser.create!(tg_user_id: 222, role: 'agent', first_name: 'B', is_manager: false, status: 'active')
    run("stage:#{lead.id}:show", user: other)
    expect(lead.reload.current_stage).to eq('first_contact')
  end
end
```

- [ ] **Step 2: Callback**

```ruby
# app/services/telegram/work_bot/callbacks/stage_callback.rb
# frozen_string_literal: true

module Telegram
  module WorkBot
    module Callbacks
      # BOTTLENECK — «единственное новое действие, которое ложится на людей» —
      # движение лида по стадиям — должно быть одним нажатием, иначе базовая
      # линия не соберётся. callback_data: "stage:<lead_event_id>:show|contract".
      # Только две кнопки: закрытие (/close) и откат (/unstage) остаются текстом —
      # это редкие и осознанные действия.
      class StageCallback < Base
        ALLOWED = ['show', 'contract'].freeze

        def handle
          stage = @args[1].to_s
          return ack("⚠️ Кнопкой доступно: #{ALLOWED.join(', ')}", alert: true) unless ALLOWED.include?(stage)

          lead = lead_event
          return ack('🚫 Стадию меняет assignee или руководитель', alert: true) unless authorized?(lead)
          return ack("ℹ️ Лид уже в стадии #{stage}") if lead.current_stage == stage

          result = LeadStageTransition.new(lead, stage, actor: tg_user, client: client).call
          return ack("⚠️ #{result.message}", alert: true) unless result.success?

          nudge_segment(lead.reload) if stage == 'show' && lead.segment.blank?
          ack("#{result.prev_stage} → #{result.new_stage} ✅")
        end

        private

        def authorized?(lead)
          return false if tg_user.nil?

          lead.assigned_to_id == tg_user.id || tg_user.manager_or_director?
        end

        def nudge_segment(lead)
          reply_in_topic(SegmentKeyboard.prompt_text, reply_markup: SegmentKeyboard.for(lead))
        rescue Telegram::Client::Error => e
          Rails.logger.warn("[StageCallback] segment nudge failed: #{e.message}")
        end
      end
    end
  end
end
```

`Callbacks::Base#reply_in_topic(text, **opts)` — проверить по `callbacks/base.rb:79-87`, что `opts` уходят в `send_message` (нужен `reply_markup`). Если нет — пробросить.

- [ ] **Step 3: Прогнать**

Run: `bin/rb --db bundle exec rspec spec/services/telegram/work_bot/callbacks/stage_callback_spec.rb`
Expected: PASS

- [ ] **Step 4: Нудж в `/stage`** — в `commands/stage.rb#handle`, в ветке `if result.success?`:

```ruby
          if result.success?
            reply("Лид ##{lead.id}: #{result.prev_stage} → <b>#{result.new_stage}</b> ✅")
            # BOTTLENECK — показ без сегмента не попадёт в сравнение конверсий.
            reply(SegmentKeyboard.prompt_text, reply_markup: SegmentKeyboard.for(lead)) if new_stage == 'show' && lead.reload.segment.blank?
          else
```

- [ ] **Step 5: Спека команды `/stage` (новый файл, покрывает и старое поведение)**

```ruby
# spec/services/telegram/work_bot/commands/stage_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Commands::Stage do
  let(:tg_client) do
    instance_double(Telegram::Client, send_message: { 'message_id' => 1 }, edit_message_text: { 'message_id' => 1 })
  end
  let(:agent) { TelegramUser.create!(tg_user_id: 111, role: 'agent', first_name: 'A', is_manager: false, status: 'active') }
  let!(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'tg_dm', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_123, anchor_message_id: 9000, assigned_to: agent)
  end

  def run(args)
    msg = { 'chat' => { 'id' => -100_123, 'type' => 'supergroup' }, 'from' => { 'id' => 111 }, 'message_id' => 5,
            'reply_to_message' => { 'message_id' => 9000 }, 'text' => "/stage #{args}" }
    described_class.new(message: msg, args: args, tg_user: agent, client: tg_client).send(:handle)
  end

  it '/stage показ без сегмента → переход + клавиатура сегмента' do
    run('показ')
    expect(lead.reload.current_stage).to eq('show')
    expect(tg_client).to have_received(:send_message)
      .with(a_string_including('сегмент'), hash_including(reply_markup: hash_including(:inline_keyboard)))
  end

  it '/stage показ с сегментом → без нуджа' do
    lead.update!(segment: 'cold')
    run('показ')
    expect(tg_client).to have_received(:send_message).once
  end

  it 'неизвестная стадия → подсказка' do
    run('лунная')
    expect(tg_client).to have_received(:send_message).with(a_string_including('Неизвестная стадия'), anything)
  end
end
```

Run: `bin/rb --db bundle exec rspec spec/services/telegram/work_bot/commands/stage_spec.rb` → PASS

- [ ] **Step 6: Линтер, коммит, стек PR A**

```bash
bin/rb bundle exec rubocop app/services/telegram/work_bot/callbacks/stage_callback.rb app/services/telegram/work_bot/commands/stage.rb spec/services/telegram/work_bot
git add app/services/telegram/work_bot spec/services/telegram/work_bot
git commit -m "feat(work_bot): кнопки стадий 📅 Показ / ✍️ Договор + нудж про сегмент

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

Открыть PR стека A (`gh stack init claude/show-delegation`, `gh stack submit --open`), дождаться 9 проверок, `/code-review <PR#> high`, закрыть блокеры. Стек B начинать веткой поверх A.

---

## Стек B — отчёт о показе

### Task 4: Модель `ShowReport`

**Files:**
- Create: `db/migrate/20260911100100_create_show_reports.rb`
- Create: `app/models/show_report.rb`
- Test: `spec/models/show_report_spec.rb`

**Interfaces:**
- Consumes: `LeadEvent#show_reports` (Task 1), `TelegramUser`, `Property`, `Task`.
- Produces: `ShowReport` с колонками ниже; enums `outcome` (`outcome_thinking?` …), `status` (`status_pending_confirm?`/`confirmed`/`cancelled`), `source` (`source_voice?`/`text`); методы `#confirm!`, `#cancel!`, `#conducted_by_director?`, `#objections_list -> Array<String>`, `#toggle_conductor!(reporter:, director:)`; скоупы `confirmed_in(range)`, `for_property(property)`; `ShowReport::OUTCOME_LABELS`.

- [ ] **Step 1: Миграция**

```ruby
# db/migrate/20260911100100_create_show_reports.rb
# frozen_string_literal: true

# BOTTLENECK — один показ = одна запись. До этого «показ проведён» существовало
# как стадия лида (без даты, без исхода) и как голосовое в чате (без данных).
# Возражения впервые становятся данными: «семь показов, пять раз кухня» —
# это и есть предметный разговор о цене с собственником (Шаг 4, этап 4).
#
# conducted_by ≠ reported_by: в базовой линии показывает руководитель, а
# диктует агент; после включения фильтра — наоборот. Именно пара
# (segment, conducted_by.role) и есть ось эксперимента.
#
# Не ViewingSchedule: та модель расходится со схемой (preferred_date которой нет
# в таблице) и нерабочая; строить на ней — унаследовать поломку.
class CreateShowReports < ActiveRecord::Migration[8.1]
  def change
    create_table :show_reports do |t|
      t.references :lead_event,   null: false, foreign_key: true
      t.references :property,     foreign_key: true
      t.references :conducted_by, null: false, foreign_key: { to_table: :telegram_users }
      t.references :reported_by,  null: false, foreign_key: { to_table: :telegram_users }
      t.datetime :conducted_at,   null: false
      t.string   :outcome,        null: false, default: 'thinking'  # thinking | declined | second_show | bargain | deposit_intent
      t.jsonb    :objections,     null: false, default: []          # ['маленькая кухня', 'первый этаж']
      t.decimal  :offered_price,  precision: 15, scale: 2           # цена, названная покупателем (торг)
      t.string   :next_step                                          # «перезвонят в пятницу»
      t.text     :transcript_redacted                                # PII-маскированный транскрипт
      t.text     :owner_message                                      # черновик сообщения собственнику
      t.datetime :owner_notified_at
      t.string   :owner_notified_via                                 # tg | manual
      t.bigint   :feedback_task_id                                   # Task «обратная связь до 11:00», FK логический
      t.string   :source,         null: false                        # voice | text
      t.string   :status,         null: false, default: 'pending_confirm' # pending_confirm | confirmed | cancelled
      t.bigint   :preview_message_id
      t.bigint   :preview_chat_id
      t.jsonb    :uncertainties,  null: false, default: []
      t.datetime :deleted_at
      t.timestamps
    end
    add_index :show_reports, %i[property_id conducted_at]
    add_index :show_reports, %i[status conducted_at]
    add_index :show_reports, :deleted_at
    add_index :show_reports, :reported_by_id, where: "status = 'pending_confirm'", name: 'idx_show_reports_pending_by_reporter'
  end
end
```

Run: `bin/rb --db bin/rails db:migrate` → проверить `db/structure.sql`.

- [ ] **Step 2: Спека модели (красная)**

```ruby
# spec/models/show_report_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ShowReport do
  let(:agent)    { TelegramUser.create!(tg_user_id: 111, role: 'agent', first_name: 'A', status: 'active') }
  let(:director) { TelegramUser.create!(tg_user_id: 333, role: 'director', first_name: 'O', status: 'active') }
  let(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'tg_dm', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1, assigned_to: agent)
  end

  def build_report(attrs = {})
    described_class.new({
      lead_event: lead, conducted_by: director, reported_by: agent,
      conducted_at: Time.current, source: 'voice', objections: ['кухня', 'первый этаж']
    }.merge(attrs))
  end

  it 'валидна с минимальным набором и pending по умолчанию' do
    r = build_report
    expect(r).to be_valid
    expect(r.status_pending_confirm?).to be(true)
    expect(r.outcome_thinking?).to be(true)
  end

  it 'OUTCOME_LABELS покрывает все исходы' do
    expect(described_class::OUTCOME_LABELS.keys).to match_array(described_class.outcomes.keys)
  end

  it '#confirm! и #cancel! идемпотентны по статусу' do
    r = build_report.tap(&:save!)
    r.confirm!
    expect(r.status_confirmed?).to be(true)
    expect { r.cancel! }.not_to(change { r.reload.status })
  end

  it '#conducted_by_director? по роли показывающего' do
    expect(build_report.conducted_by_director?).to be(true)
    expect(build_report(conducted_by: agent).conducted_by_director?).to be(false)
  end

  it '#toggle_conductor! переключает между reporter и director' do
    r = build_report.tap(&:save!)
    r.toggle_conductor!(reporter: agent, director: director)
    expect(r.conducted_by).to eq(agent)
    r.toggle_conductor!(reporter: agent, director: director)
    expect(r.conducted_by).to eq(director)
  end

  it 'soft-delete скрывает запись из default_scope' do
    r = build_report.tap(&:save!)
    r.update!(deleted_at: Time.current)
    expect(described_class.find_by(id: r.id)).to be_nil
    expect(described_class.unscoped.find(r.id)).to eq(r)
  end

  it '.confirmed_in и .for_property' do
    property = create(:property)
    r = build_report(property: property, status: 'confirmed', conducted_at: 2.days.ago).tap(&:save!)
    build_report(property: property, conducted_at: 2.days.ago).save!
    expect(described_class.confirmed_in(3.days.ago..Time.current)).to contain_exactly(r)
    expect(described_class.for_property(property).count).to eq(2)
  end

  it '#objections_list чистит пустые и приводит к строкам' do
    expect(build_report(objections: ['Кухня ', nil, '', 'этаж']).objections_list).to eq(['кухня', 'этаж'])
  end
end
```

- [ ] **Step 3: Модель**

```ruby
# app/models/show_report.rb
# frozen_string_literal: true

# BOTTLENECK — факт показа с обратной связью покупателя. См. миграцию 20260911100100.
class ShowReport < ApplicationRecord
  # === Associations ===
  belongs_to :lead_event
  belongs_to :property, optional: true
  belongs_to :conducted_by, class_name: 'TelegramUser'   # кто показывал
  belongs_to :reported_by,  class_name: 'TelegramUser'   # кто надиктовал/написал

  # === Enums (правило 2 CLAUDE.md — prefix обязателен) ===
  enum :outcome, {
    thinking: 'thinking',             # думают / взяли паузу
    declined: 'declined',             # отказ
    second_show: 'second_show',       # хотят второй показ
    bargain: 'bargain',               # назвали цену / торг
    deposit_intent: 'deposit_intent'  # готовы к задатку
  }, prefix: true

  OUTCOME_LABELS = {
    'thinking'       => '🤔 Думают',
    'declined'       => '❌ Отказ',
    'second_show'    => '🔁 Второй показ',
    'bargain'        => '💬 Торг',
    'deposit_intent' => '✍️ Готовы к задатку'
  }.freeze

  enum :status, {
    pending_confirm: 'pending_confirm', # ждёт подтверждения в DM
    confirmed: 'confirmed',             # подтверждён — учитывается в метриках
    cancelled: 'cancelled'              # отменён
  }, prefix: true

  enum :source, {
    voice: 'voice', # голосовое
    text: 'text'    # /show текстом
  }, prefix: true

  # === Soft-delete (правило 1) ===
  scope :not_deleted, -> { where(deleted_at: nil) }
  default_scope { not_deleted }

  # === Validations ===
  validates :conducted_at, presence: true

  # === Scopes ===
  scope :confirmed_in, ->(range) { status_confirmed.where(conducted_at: range) }
  scope :for_property, ->(property) { where(property_id: property.id) }

  def confirm!
    return self unless status_pending_confirm?

    update!(status: 'confirmed')
    self
  end

  def cancel!
    return self unless status_pending_confirm?

    update!(status: 'cancelled')
    self
  end

  def conducted_by_director?
    conducted_by.role_director? || conducted_by.role_admin?
  end

  def outcome_label
    OUTCOME_LABELS[outcome] || outcome
  end

  def objections_list
    Array(objections).map { |o| o.to_s.strip.downcase }.compact_blank
  end

  # Превью даёт одну кнопку «показывал(а) я / руководитель» — переключатель
  # между тем, кто диктует, и директором. Третьего варианта в агентстве нет.
  def toggle_conductor!(reporter:, director:)
    target = conducted_by_id == director&.id ? reporter : director
    return self if target.nil?

    update!(conducted_by: target)
    self
  end
end
```

Здесь же — обратная связь на стороне лида, которую Task 1 намеренно не объявлял (до этой миграции она роняла `LeadEvent#destroy`). В `app/models/lead_event.rb`, рядом с `belongs_to :property`:

```ruby
  has_many :show_reports, dependent: :nullify
```

Проверка, что связь теперь безопасна: `bin/rb --db bundle exec rspec spec/services/lead/intake_spec.rb` — там есть пример с `existing.destroy!`.

- [ ] **Step 4: Протухание неподтверждённых отчётов**

`TaskBatch` после часа в `pending` помечается `expired` кроном (`TaskBatchExpiryJob`, `*/10 * * * *`). У `ShowReport` такого пути нет, и без него неподтверждённый отчёт висит вечно: превью в личке живое, кнопка ✅ работает через неделю, а метрика «показов без отчёта» (`Kpi::ShowFunnel#unreported_count`, Task 9) считает показ неотчитанным, хотя отчёт надиктован и ждёт одной кнопки. Две недели базовой линии такое расхождение проходит незамеченным.

В enum статусов (`app/models/show_report.rb`) добавить четвёртое значение и метод:

```ruby
  enum :status, {
    pending_confirm: 'pending_confirm', # ждёт подтверждения в DM
    confirmed: 'confirmed',             # подтверждён — учитывается в метриках
    cancelled: 'cancelled',             # отменён
    expired: 'expired'                  # висел в pending > 1 часа, снят кроном
  }, prefix: true
```

```ruby
  scope :expired_candidates, ->(older_than:) { status_pending_confirm.where(created_at: ...older_than) }

  # BOTTLENECK — симметрично TaskBatch: неподтверждённый отчёт не живёт вечно.
  # Иначе «показов без отчёта» в недельной сводке показывает показ как
  # неотчитанный, хотя отчёт надиктован и ждёт одной кнопки.
  def expire!
    return self unless status_pending_confirm?

    update!(status: 'expired')
    self
  end
```

В миграции (Step 1) поправить комментарий у колонки: `# pending_confirm | confirmed | cancelled | expired`.

В `app/jobs/task_batch_expiry_job.rb` — второй проход в том же кроне, отдельный джоб и отдельная строка расписания не нужны:

```ruby
  def perform
    batches = expire_batches
    reports = expire_show_reports
    return :no_pending if batches.zero? && reports.zero?

    { expired: batches, expired_show_reports: reports }
  end

  private

  def expire_batches
    candidates = TaskBatch.expired_candidates(older_than: EXPIRY_AGE.ago)
    count = candidates.count
    return 0 if count.zero?

    candidates.find_each(&:expire!)
    Rails.logger.info("[TaskBatchExpiryJob] expired #{count} batches (pending > #{EXPIRY_AGE.inspect})")
    count
  end

  # BOTTLENECK — см. ShowReport#expire!. Тот же час, тот же крон.
  def expire_show_reports
    candidates = ShowReport.expired_candidates(older_than: EXPIRY_AGE.ago)
    count = candidates.count
    return 0 if count.zero?

    candidates.find_each(&:expire!)
    Rails.logger.info("[TaskBatchExpiryJob] expired #{count} show_reports (pending > #{EXPIRY_AGE.inspect})")
    count
  end
```

Спека — в `spec/models/show_report_spec.rb` (Step 2):

```ruby
  describe '#expire!' do
    it 'pending > часа снимается, confirmed не трогается' do
      stale = create_report!(created_at: 2.hours.ago)
      fresh = create_report!(created_at: 5.minutes.ago)
      done  = create_report!(created_at: 3.hours.ago).confirm!

      ShowReport.expired_candidates(older_than: 1.hour.ago).find_each(&:expire!)

      expect(stale.reload.status_expired?).to be(true)
      expect(fresh.reload.status_pending_confirm?).to be(true)
      expect(done.reload.status_confirmed?).to be(true)
    end
  end
```

`create_report!` — хелпер этой же спеки (Step 2); если он там назван иначе, использовать существующий и передать `created_at:`.

Run: `bin/rb --db bundle exec rspec spec/models/show_report_spec.rb -e expire`
Expected: PASS

- [ ] **Step 5: Прогнать, линтер, коммит**

```bash
bin/rb --db bundle exec rspec spec/models/show_report_spec.rb
bin/rb bundle exec rubocop app/models/show_report.rb spec/models/show_report_spec.rb
git add db/migrate/20260911100100_create_show_reports.rb db/structure.sql app/models/show_report.rb \
        app/jobs/task_batch_expiry_job.rb spec/models/show_report_spec.rb
git commit -m "feat(shows): модель ShowReport — факт показа, исход, возражения, черновик собственнику

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: `ShowReports::Extractor` — LLM раскладывает транскрипт

**Files:**
- Create: `app/services/telegram/work_bot/show_reports/extractor.rb`
- Test: `spec/services/telegram/work_bot/show_reports/extractor_spec.rb`

**Interfaces:**
- Consumes: `Llm::OmniClient#complete(messages, chain:, response_format:, temperature:, max_tokens:) -> { content:, model: }`; `LeadEvent#property`, `#metadata['name']`, `#segment`.
- Produces: `Telegram::WorkBot::ShowReports::Extractor.call(transcript:, candidates:, reporter:, now:, client:) -> Result` где `Result = Struct(lead_id, conducted_by_director, conducted_at, outcome, objections, offered_price, next_step, owner_message, uncertainties, model, error)` + `#success?`. `candidates` — `Array<LeadEvent>` (открытые лиды, из которых LLM выбирает `lead_id`; может быть пустым — тогда `lead_id` всегда nil). Если `lead_id` известен заранее (команда `/show`), передавать `candidates: [lead]`.

- [ ] **Step 1: Спека (красная)**

```ruby
# spec/services/telegram/work_bot/show_reports/extractor_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::ShowReports::Extractor do
  # Стаб OmniClient в стиле voice_intent_branch_spec — DI через client:.
  class StubOmniForShowReport # rubocop:disable Lint/ConstantDefinitionInBlock
    attr_reader :last_messages

    def initialize(content: nil, raise: nil)
      @content = content
      @raise = raise
    end

    def complete(messages, **_opts)
      @last_messages = messages
      raise @raise if @raise

      { content: @content, model: 'stub' }
    end
  end

  let(:agent) { TelegramUser.create!(tg_user_id: 111, role: 'agent', first_name: 'Ирина', status: 'active') }
  let(:property) { create(:property, address: 'Рязань, ул. Есенина, 12', price: 5_500_000) }
  let(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'tg_dm', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1, assigned_to: agent,
                      property: property, metadata: { 'name' => 'Анна' })
  end
  let(:now) { Time.zone.parse('2026-09-11 15:00') }

  def payload(overrides = {})
    {
      lead_id: lead.id, conducted_by_director: true, conducted_at: '2026-09-11T14:00:00',
      outcome: 'thinking', objections: ['Маленькая кухня', 'первый этаж'], offered_price: nil,
      next_step: 'перезвонят в пятницу',
      owner_message: 'Анна Петровна, добрый день! Оксана провела показ...', uncertainties: []
    }.merge(overrides).to_json
  end

  it 'раскладывает валидный JSON в Result' do
    client = StubOmniForShowReport.new(content: payload)
    res = described_class.call(transcript: 'Показ Есенина 12, Оксана показывала, кухня не понравилась',
                               candidates: [lead], reporter: agent, now: now, client: client)
    expect(res).to be_success
    expect(res.lead_id).to eq(lead.id)
    expect(res.conducted_by_director).to be(true)
    expect(res.outcome).to eq('thinking')
    expect(res.objections).to eq(['маленькая кухня', 'первый этаж'])
    expect(res.conducted_at).to eq(Time.zone.parse('2026-09-11 14:00'))
    expect(res.owner_message).to include('Оксана')
  end

  it 'кандидаты уходят в промпт с id и адресом' do
    client = StubOmniForShowReport.new(content: payload)
    described_class.call(transcript: 'x', candidates: [lead], reporter: agent, now: now, client: client)
    system = client.last_messages.first[:content]
    expect(system).to include("##{lead.id}").and include('Есенина')
  end

  it 'lead_id вне кандидатов → nil + uncertainty' do
    client = StubOmniForShowReport.new(content: payload(lead_id: 999_999))
    res = described_class.call(transcript: 'x', candidates: [lead], reporter: agent, now: now, client: client)
    expect(res.lead_id).to be_nil
    expect(res.uncertainties.join).to include('лид')
  end

  it 'неизвестный outcome → thinking; цена «5,2 млн» → 5200000' do
    client = StubOmniForShowReport.new(content: payload(outcome: 'happy', offered_price: '5,2 млн'))
    res = described_class.call(transcript: 'x', candidates: [lead], reporter: agent, now: now, client: client)
    expect(res.outcome).to eq('thinking')
    expect(res.offered_price).to eq(5_200_000)
  end

  it 'conducted_at в будущем или битая → now' do
    client = StubOmniForShowReport.new(content: payload(conducted_at: 'вчера вечером'))
    res = described_class.call(transcript: 'x', candidates: [lead], reporter: agent, now: now, client: client)
    expect(res.conducted_at).to eq(now)
  end

  it 'пустой owner_message → шаблонный черновик из исхода и возражений' do
    client = StubOmniForShowReport.new(content: payload(owner_message: ''))
    res = described_class.call(transcript: 'x', candidates: [lead], reporter: agent, now: now, client: client)
    expect(res.owner_message).to include('кухня')
  end

  it 'LLM упал → error, не исключение' do
    client = StubOmniForShowReport.new(raise: StandardError.new('down'))
    res = described_class.call(transcript: 'x', candidates: [lead], reporter: agent, now: now, client: client)
    expect(res).not_to be_success
    expect(res.error).to include('down')
  end

  it 'не JSON → error' do
    client = StubOmniForShowReport.new(content: 'ага')
    res = described_class.call(transcript: 'x', candidates: [lead], reporter: agent, now: now, client: client)
    expect(res).not_to be_success
  end
end
```

- [ ] **Step 2: Extractor**

```ruby
# app/services/telegram/work_bot/show_reports/extractor.rb
# frozen_string_literal: true

module Telegram
  module WorkBot
    module ShowReports
      # BOTTLENECK — LLM-раскладка транскрипта после показа. Копия паттерна
      # TaskExtractor: Result-struct, никогда не бросает, normalize + quality gate.
      #
      # Зачем один вызов возвращает и данные, и черновик собственнику: сообщение
      # по регламенту уходит день в день до 11:00, и его всё равно пишет человек;
      # черновик из тех же возражений экономит агенту пять минут и гарантирует,
      # что в сообщении нет того, чего не было на показе.
      #
      # transcript — RAW (с PII): имена нужны для owner_message. В БД он не
      # попадает — Intake персистит только redacted-версию.
      class Extractor
        OUTCOMES = ShowReport.outcomes.keys.freeze
        MAX_CANDIDATES = 30

        Result = Struct.new(:lead_id, :conducted_by_director, :conducted_at, :outcome, :objections,
                            :offered_price, :next_step, :owner_message, :uncertainties, :model, :error,
                            keyword_init: true) do
          def success? = error.nil?
        end

        def self.call(...)
          new(...).call
        end

        def initialize(transcript:, candidates:, reporter:, now: Time.current, client: Llm::OmniClient.new)
          @transcript = transcript.to_s.strip
          @candidates = Array(candidates).first(MAX_CANDIDATES)
          @reporter   = reporter
          @now        = now
          @client     = client
        end

        def call
          return failure('пустой транскрипт') if @transcript.empty?

          res = @client.complete(
            [{ role: 'system', content: system_prompt },
             { role: 'user',   content: "Рассказ после показа:\n\n#{@transcript}" }],
            chain: :staff_analysis,
            response_format: { type: 'json_object' },
            temperature: 0.2,
            max_tokens: 900
          )
          parsed = JSON.parse(res[:content].to_s)
          build(parsed, res[:model])
        rescue JSON::ParserError => e
          failure("LLM вернул не JSON: #{e.message.truncate(80)}")
        rescue StandardError => e
          Rails.logger.error("[ShowReports::Extractor] #{e.class}: #{e.message}")
          failure(e.message)
        end

        private

        def failure(error)
          Result.new(objections: [], uncertainties: [], error: error)
        end

        def build(parsed, model)
          uncertainties = Array(parsed['uncertainties']).map(&:to_s).compact_blank
          lead_id = resolve_lead_id(parsed['lead_id'], uncertainties)
          objections = Array(parsed['objections']).map { |o| o.to_s.strip.downcase }.compact_blank.uniq.first(10)
          outcome = OUTCOMES.include?(parsed['outcome'].to_s) ? parsed['outcome'].to_s : 'thinking'

          Result.new(
            lead_id: lead_id,
            conducted_by_director: parsed['conducted_by_director'] == true,
            conducted_at: parse_time(parsed['conducted_at']),
            outcome: outcome,
            objections: objections,
            offered_price: parse_price(parsed['offered_price']),
            next_step: parsed['next_step'].to_s.strip.presence&.truncate(200),
            owner_message: parsed['owner_message'].to_s.strip.presence || template_owner_message(outcome, objections),
            uncertainties: uncertainties,
            model: model,
            error: nil
          )
        end

        def resolve_lead_id(raw, uncertainties)
          id = raw.to_i
          return id if id.positive? && @candidates.any? { |c| c.id == id }

          uncertainties << 'не удалось определить, по какому лиду показ' if @candidates.any?
          nil
        end

        def parse_time(raw)
          t = Time.zone.parse(raw.to_s)
          return @now if t.nil? || t > @now + 5.minutes || t < @now - 30.days

          t
        rescue ArgumentError
          @now
        end

        # «5,2 млн» / «5 200 000» / «5.2млн» / 5200000 → Decimal или nil.
        def parse_price(raw)
          return nil if raw.blank?
          return raw.to_d if raw.is_a?(Numeric)

          s = raw.to_s.downcase.gsub(/\s/, '').tr(',', '.')
          millions = s.include?('млн')
          num = s[/\d+(?:\.\d+)?/]
          return nil if num.nil?

          value = num.to_d
          value *= 1_000_000 if millions
          value.positive? ? value : nil
        end

        def template_owner_message(outcome, objections)
          what = ShowReport::OUTCOME_LABELS[outcome].to_s.sub(/\A\S+\s/, '').downcase
          tail = objections.any? ? " Смутило: #{objections.join(', ')}." : ''
          "Добрый день! Это #{@reporter.first_name.presence || 'агент'}, АН «Виктори». " \
            "Провели показ вашей квартиры. Покупатели: #{what}.#{tail} Держим с ними связь, " \
            'как будет конкретика — сразу сообщу.'
        end

        def system_prompt
          <<~PROMPT.strip
            Ты — ассистент агентства недвижимости «Виктори». Сотрудник рассказывает (голосом) о только что
            проведённом показе квартиры. Извлеки структурированные данные в JSON.

            Открытые лиды сотрудника (выбери lead_id по адресу/имени покупателя; если не уверен — null):
            #{candidates_block}

            Сейчас: #{@now.strftime('%d.%m.%y %H:%M')} (Москва). Рассказчик: #{@reporter.first_name.presence || 'сотрудник'}
            (роль: #{@reporter.role}).

            Поля:
            - lead_id: число из списка выше или null.
            - conducted_by_director: true, если показ проводил руководитель (Оксана / директор), false — если сам рассказчик.
            - conducted_at: ISO8601 момент показа («только что» → сейчас, «утром» → сегодня 10:00, «вчера» → вчера 12:00).
            - outcome: один из #{OUTCOMES.join(' | ')} (thinking — думают/пауза, declined — отказ,
              second_show — хотят прийти ещё, bargain — назвали свою цену, deposit_intent — готовы к задатку).
            - objections: массив коротких тегов на русском в нижнем регистре, 1–4 слова каждый, что не понравилось
              («маленькая кухня», «первый этаж», «шумная дорога»). Одинаковые — один раз. Пусто, если возражений не было.
            - offered_price: число в рублях, если покупатель назвал цену, иначе null.
            - next_step: короткая фраза о следующем шаге или null.
            - owner_message: готовое сообщение собственнику от имени рассказчика, 2–4 предложения, тёплый тон,
              без цифр торга, без телефонов, только факты из рассказа. Начни с «Добрый день!».
            - uncertainties: массив строк — что осталось непонятным.

            Верни СТРОГО JSON:
            {"lead_id": 12, "conducted_by_director": true, "conducted_at": "2026-09-11T14:00:00",
             "outcome": "thinking", "objections": ["маленькая кухня"], "offered_price": null,
             "next_step": "перезвонят в пятницу", "owner_message": "Добрый день! ...", "uncertainties": []}
          PROMPT
        end

        def candidates_block
          return '(список пуст — lead_id всегда null)' if @candidates.empty?

          @candidates.map do |lead|
            address = lead.property&.address.presence || lead.metadata['summary'].to_s.truncate(60).presence || 'адрес неизвестен'
            name    = lead.metadata['name'].presence || 'имя неизвестно'
            "  • ##{lead.id} — #{address} — покупатель: #{name} — стадия: #{lead.current_stage}"
          end.join("\n")
        end
      end
    end
  end
end
```

- [ ] **Step 3: Прогнать, линтер, коммит**

```bash
bin/rb --db bundle exec rspec spec/services/telegram/work_bot/show_reports/extractor_spec.rb
bin/rb bundle exec rubocop app/services/telegram/work_bot/show_reports spec/services/telegram/work_bot/show_reports
git add app/services/telegram/work_bot/show_reports spec/services/telegram/work_bot/show_reports
git commit -m "feat(shows): ShowReports::Extractor — LLM раскладывает рассказ о показе в исход, возражения, черновик собственнику

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---
### Task 6: `ShowReports::Intake` + `Confirmer` — от транскрипта до превью с кнопками

**Files:**
- Create: `app/services/telegram/work_bot/show_reports/intake.rb`
- Create: `app/services/telegram/work_bot/show_reports/confirmer.rb`
- Test: `spec/services/telegram/work_bot/show_reports/intake_spec.rb`, `spec/services/telegram/work_bot/show_reports/confirmer_spec.rb`

**Interfaces:**
- Consumes: `Extractor.call(...) -> Result` (Task 5); `ShowReport` (Task 4); `Lead::PropertyResolver.call(lead)` (Task 1); `Telegram::Client#send_message`.
- Produces:
  - `ShowReports::Intake.new(reporter:, transcript_raw:, transcript_redacted:, source:, chat_id:, lead: nil, client:, extractor: Extractor).call -> Result(ok, report, message)`; при `ok: false` `message` — текст подсказки для ответа пользователю (Intake сам ничего не шлёт, кроме превью через Confirmer).
  - `ShowReports::Confirmer.new(report:, client:).call -> Hash` (ответ Telegram); сохраняет `preview_message_id/preview_chat_id`; `Confirmer#preview_text -> String`, `Confirmer#keyboard -> Hash`.
  - `Intake::PENDING_LIMIT_MESSAGE`, `Intake.candidates_for(reporter) -> ActiveRecord::Relation`.

- [ ] **Step 1: Спека Confirmer (красная)**

```ruby
# spec/services/telegram/work_bot/show_reports/confirmer_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::ShowReports::Confirmer do
  let(:tg_client) { instance_double(Telegram::Client, send_message: { 'message_id' => 505 }) }
  let(:agent)    { TelegramUser.create!(tg_user_id: 111, role: 'agent', first_name: 'Ирина', status: 'active', dm_chat_id: 111) }
  let(:director) { TelegramUser.create!(tg_user_id: 333, role: 'director', first_name: 'Оксана', status: 'active') }
  let(:property) { create(:property, address: 'Рязань, ул. Есенина, 12') }
  let(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'tg_dm', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1, assigned_to: agent, property: property,
                      metadata: { 'name' => 'Анна' })
  end
  let(:report) do
    ShowReport.create!(lead_event: lead, property: property, conducted_by: director, reported_by: agent,
                       conducted_at: Time.zone.parse('2026-09-11 14:00'), source: 'voice', outcome: 'bargain',
                       objections: ['маленькая кухня'], offered_price: 5_200_000, next_step: 'перезвонят в пятницу',
                       owner_message: 'Добрый день! ...', uncertainties: ['не понял этаж'])
  end

  subject(:confirmer) { described_class.new(report: report, client: tg_client) }

  it 'превью содержит адрес, покупателя, показывающего, исход, возражения, цену, дату dd.MM.yy' do
    text = confirmer.preview_text
    expect(text).to include('Есенина', 'Анна', 'Оксана', '💬 Торг', 'маленькая кухня', '11.09.26 14:00')
    expect(text).to include('5 200 000')
    expect(text).to include('не понял этаж')
  end

  it 'клавиатура: сохранить / переключить показывающего / отмена' do
    data = confirmer.keyboard[:inline_keyboard].flatten.map { |b| b[:callback_data] }
    expect(data).to contain_exactly("show_report:#{report.id}:approve",
                                    "show_report:#{report.id}:toggle_conductor",
                                    "show_report:#{report.id}:cancel")
    data.each { |d| expect(d.bytesize).to be <= 64 }
  end

  it '#call шлёт превью в DM и сохраняет message_id' do
    confirmer.call
    expect(tg_client).to have_received(:send_message)
      .with(a_string_including('Подтверди отчёт о показе'), hash_including(chat_id: 111, parse_mode: 'HTML'))
    expect(report.reload.preview_message_id).to eq(505)
    expect(report.preview_chat_id).to eq(111)
  end

  it 'HTML в возражениях экранируется' do
    report.update!(objections: ['<b>кухня</b>'])
    expect(confirmer.preview_text).to include('&lt;b&gt;кухня&lt;/b&gt;')
  end
end
```

- [ ] **Step 2: Confirmer**

```ruby
# app/services/telegram/work_bot/show_reports/confirmer.rb
# frozen_string_literal: true

module Telegram
  module WorkBot
    module ShowReports
      # BOTTLENECK — превью отчёта о показе в DM рассказчику с кнопками
      # [✅ Сохранить] [👤 Показывал(а): …] [✖️ Отмена]. Аналог TaskBatchConfirmer.
      # Без подтверждения запись не попадает в метрики — LLM ошибается, и
      # человек должен это увидеть до того, как цифра ушла в отчёт директору.
      class Confirmer
        def initialize(report:, client: Telegram::Client.new)
          @report = report
          @client = client
        end

        def call
          chat_id = @report.reported_by.dm_chat_id || @report.reported_by.tg_user_id
          msg = @client.send_message(preview_text, chat_id: chat_id, parse_mode: 'HTML', reply_markup: keyboard)
          @report.update!(preview_message_id: msg['message_id'], preview_chat_id: chat_id)
          msg
        end

        def preview_text
          lead = @report.lead_event
          lines = ["🏠 <b>Подтверди отчёт о показе</b> (##{@report.id})", '']
          lines << "Объект: #{escape(address)}"
          lines << "Покупатель: #{escape(lead.metadata['name'].presence || "лид ##{lead.id}")} · #{lead.segment_label}"
          lines << "Показывал(а): <b>#{escape(@report.conducted_by.display_name)}</b>"
          lines << "Когда: #{Formatters::DateFormat.fmt_dt(@report.conducted_at)}"
          lines << "Исход: <b>#{@report.outcome_label}</b>"
          lines << "Возражения: #{@report.objections_list.any? ? escape(@report.objections_list.join(', ')) : '—'}"
          lines << "Названная цена: #{price_line}" if @report.offered_price.present?
          lines << "Дальше: #{escape(@report.next_step)}" if @report.next_step.present?
          if @report.uncertainties.any?
            lines << ''
            lines << '⚠️ <b>Уточнения:</b>'
            @report.uncertainties.each { |u| lines << "  • #{escape(u)}" }
          end
          lines << ''
          lines << '<i>Черновик собственнику (пришлю после сохранения):</i>'
          lines << "<i>#{escape(@report.owner_message.to_s.truncate(400))}</i>"
          lines.join("\n")
        end

        def keyboard
          toggle = @report.conducted_by_director? ? '👤 Показывал(а) я' : '👑 Показывал руководитель'
          {
            inline_keyboard: [
              [{ text: '✅ Сохранить', callback_data: "show_report:#{@report.id}:approve" }],
              [{ text: toggle, callback_data: "show_report:#{@report.id}:toggle_conductor" }],
              [{ text: '✖️ Отмена', callback_data: "show_report:#{@report.id}:cancel" }]
            ]
          }
        end

        private

        def address
          @report.property&.address.presence || @report.lead_event.metadata['summary'].to_s.truncate(80).presence || 'объект не определён'
        end

        def price_line
          "#{ActiveSupport::NumberHelper.number_to_delimited(@report.offered_price.to_i, delimiter: ' ')} ₽"
        end

        def escape(text)
          text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
        end
      end
    end
  end
end
```

`TelegramUser#display_name` существует (используется в `owner_intake_processor.rb`). Если `Formatters::DateFormat.fmt_dt` принимает только Time — `conducted_at` уже Time.

Run: `bin/rb --db bundle exec rspec spec/services/telegram/work_bot/show_reports/confirmer_spec.rb` → PASS

- [ ] **Step 3: Спека Intake (красная)**

```ruby
# spec/services/telegram/work_bot/show_reports/intake_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::ShowReports::Intake do
  let(:tg_client) { instance_double(Telegram::Client, send_message: { 'message_id' => 505 }) }
  let(:agent)     { TelegramUser.create!(tg_user_id: 111, role: 'agent', first_name: 'Ирина', status: 'active', dm_chat_id: 111) }
  let!(:director) { TelegramUser.create!(tg_user_id: 333, role: 'director', first_name: 'Оксана', status: 'active') }
  let(:property)  { create(:property) }
  let!(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'tg_dm', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1, assigned_to: agent, property: property)
  end
  let(:extractor) { class_double(Telegram::WorkBot::ShowReports::Extractor) }

  def extraction(overrides = {})
    Telegram::WorkBot::ShowReports::Extractor::Result.new({
      lead_id: lead.id, conducted_by_director: true, conducted_at: Time.current, outcome: 'thinking',
      objections: ['кухня'], offered_price: nil, next_step: nil, owner_message: 'Добрый день!',
      uncertainties: [], model: 'stub', error: nil
    }.merge(overrides))
  end

  def run(lead_arg: nil, transcript: 'показ Есенина, кухня не понравилась')
    described_class.new(reporter: agent, transcript_raw: transcript, transcript_redacted: transcript,
                        source: 'voice', chat_id: 111, lead: lead_arg, client: tg_client, extractor: extractor).call
  end

  it 'счастливый путь: pending ShowReport + превью' do
    allow(extractor).to receive(:call).and_return(extraction)
    res = run
    expect(res.ok).to be(true)
    report = res.report
    expect(report.status_pending_confirm?).to be(true)
    expect(report.conducted_by).to eq(director)
    expect(report.property).to eq(property)
    expect(report.transcript_redacted).to be_present
    expect(tg_client).to have_received(:send_message).with(a_string_including('Подтверди'), anything)
  end

  it 'conducted_by_director=false → показывал рассказчик' do
    allow(extractor).to receive(:call).and_return(extraction(conducted_by_director: false))
    expect(run.report.conducted_by).to eq(agent)
  end

  it 'явный lead: (из /show) — в extractor уходит только он' do
    allow(extractor).to receive(:call).and_return(extraction)
    run(lead_arg: lead)
    expect(extractor).to have_received(:call).with(hash_including(candidates: [lead]))
  end

  it 'лид не определён → ok:false с подсказкой и списком открытых лидов, записи нет' do
    allow(extractor).to receive(:call).and_return(extraction(lead_id: nil, uncertainties: ['не понял лид']))
    res = run
    expect(res.ok).to be(false)
    expect(res.message).to include('/show', "/show #{lead.id}")
    expect(ShowReport.count).to eq(0)
  end

  # Поймано на исполнении 12.09.26: подсказка выводит id внутри готовой команды
  # (`/show 1`), а форма «#1» есть только в fallback'е, когда у лида нет ни
  # адреса, ни имени покупателя. Проверяем то, что человек копирует.
  it 'у рассказчика уже есть неподтверждённый отчёт → отказ с номером' do
    ShowReport.create!(lead_event: lead, conducted_by: director, reported_by: agent, conducted_at: Time.current, source: 'voice')
    allow(extractor).to receive(:call).and_return(extraction)
    res = run
    expect(res.ok).to be(false)
    expect(res.message).to include('неподтверждённый')
  end

  it 'ошибка extractor → ok:false, текст ошибки' do
    allow(extractor).to receive(:call).and_return(extraction(error: 'LLM down'))
    expect(run.message).to include('LLM down')
  end

  it 'закрытый лид не попадает в кандидаты' do
    lead.update!(current_stage: 'closed_lost')
    expect(described_class.candidates_for(agent)).to be_empty
  end

  it 'директор видит кандидатов всех агентов' do
    expect(described_class.candidates_for(director)).to include(lead)
  end
end
```

- [ ] **Step 4: Intake**

```ruby
# app/services/telegram/work_bot/show_reports/intake.rb
# frozen_string_literal: true

module Telegram
  module WorkBot
    module ShowReports
      # BOTTLENECK — общий вход для голосового и `/show`: извлечь → создать
      # pending ShowReport → показать превью. Сам ничего не отвечает при
      # ошибке: возвращает Result с текстом, который вызывающий шлёт тем
      # способом, который у него есть (edit_ack у voice, reply у команды).
      class Intake
        Result = Struct.new(:ok, :report, :message, keyword_init: true)

        PENDING_LIMIT_MESSAGE = '🚫 У тебя есть неподтверждённый отчёт о показе <b>#%<id>d</b>. ' \
                                'Сохрани или отмени его кнопками в превью, потом присылай новый.'

        # Открытые лиды, из которых LLM выбирает: агент — свои, руководитель — все.
        # Порядок по updated_at: только что показанный лид почти наверняка
        # трогали (стадия/заметка) — он окажется первым в промпте.
        def self.candidates_for(reporter)
          scope = LeadEvent.real.open.includes(:property).order(updated_at: :desc)
          reporter.manager_or_director? ? scope : scope.for_agent(reporter)
        end

        def initialize(reporter:, transcript_raw:, transcript_redacted:, source:, chat_id:, lead: nil,
                       client: Telegram::Client.new, extractor: Extractor)
          @reporter = reporter
          @transcript_raw = transcript_raw.to_s
          @transcript_redacted = transcript_redacted.to_s
          @source = source
          @chat_id = chat_id
          @lead = lead
          @client = client
          @extractor = extractor
        end

        def call
          pending = ShowReport.status_pending_confirm.where(reported_by: @reporter).order(created_at: :desc).first
          return Result.new(ok: false, message: format(PENDING_LIMIT_MESSAGE, id: pending.id)) if pending

          candidates = @lead ? [@lead] : self.class.candidates_for(@reporter).to_a
          extraction = @extractor.call(transcript: @transcript_raw, candidates: candidates,
                                       reporter: @reporter, now: Time.current)
          return Result.new(ok: false, message: "⚠️ Не удалось разобрать рассказ: #{extraction.error.to_s.truncate(120)}") unless extraction.success?

          lead = @lead || candidates.find { |c| c.id == extraction.lead_id }
          return Result.new(ok: false, message: lead_hint(candidates)) if lead.nil?

          report = create_report(lead, extraction)
          Confirmer.new(report: report, client: @client).call
          Result.new(ok: true, report: report)
        rescue StandardError => e
          Rails.logger.error("[ShowReports::Intake] #{e.class}: #{e.message}")
          Result.new(ok: false, message: "⚠️ Внутренняя ошибка: #{e.message.truncate(120)}")
        end

        private

        def create_report(lead, ex)
          ShowReport.create!(
            lead_event: lead,
            property: Lead::PropertyResolver.call(lead),
            conducted_by: conductor_for(lead, ex),
            reported_by: @reporter,
            conducted_at: ex.conducted_at || Time.current,
            outcome: ex.outcome,
            objections: ex.objections,
            offered_price: ex.offered_price,
            next_step: ex.next_step,
            owner_message: ex.owner_message,
            uncertainties: ex.uncertainties,
            transcript_redacted: @transcript_redacted.truncate(4000),
            source: @source
          )
        end

        # Кто показывал: если LLM услышал «Оксана показывала» — директор, иначе
        # рассказчик. Переключается кнопкой в превью. Стек C добавит третий
        # источник — назначенного через show_assign (metadata['show_conductor_id']).
        def conductor_for(lead, ex)
          assigned = TelegramUser.find_by(id: lead.metadata['show_conductor_id'])
          return assigned if assigned

          return @reporter unless ex.conducted_by_director

          TelegramUser.directors.active.first || @reporter
        end

        def lead_hint(candidates)
          list = candidates.first(5).map do |c|
            "  • <code>/show #{c.id}</code> — #{escape(c.property&.address.presence || c.metadata['name'].presence || "лид ##{c.id}")}"
          end
          head = '🤔 Не понял, по какому лиду показ. Напиши текстом с номером лида, например ' \
                 '<code>/show 12 показ прошёл, кухня не понравилась</code>'
          list.any? ? "#{head}\nТвои открытые лиды:\n#{list.join("\n")}" : head
        end

        def escape(text)
          text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
        end
      end
    end
  end
end
```

- [ ] **Step 5: Прогнать, линтер, коммит**

```bash
bin/rb --db bundle exec rspec spec/services/telegram/work_bot/show_reports
bin/rb bundle exec rubocop app/services/telegram/work_bot/show_reports spec/services/telegram/work_bot/show_reports
git add app/services/telegram/work_bot/show_reports spec/services/telegram/work_bot/show_reports
git commit -m "feat(shows): Intake + Confirmer — от транскрипта до превью отчёта о показе в DM

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---
### Task 7: `ShowReports::Finalizer` + `ShowReportCallback` — подтверждение, стадия, задача до 11:00, собственник

**Files:**
- Create: `app/services/telegram/work_bot/show_reports/finalizer.rb`
- Create: `app/services/telegram/work_bot/callbacks/show_report_callback.rb`
- Modify: `app/services/telegram/work_bot/callbacks_router.rb` (`PREFIX_MAP` + `'show_report'`)
- Modify: `app/services/telegram/work_bot/lead_announcer.rb#format_card_text` (строка «🏠 показов: N»)
- Test: `spec/services/telegram/work_bot/show_reports/finalizer_spec.rb`, `spec/services/telegram/work_bot/callbacks/show_report_callback_spec.rb`

**Interfaces:**
- Consumes: `ShowReport#confirm!/#cancel!/#toggle_conductor!` (Task 4); `Confirmer#preview_text/#keyboard` (Task 6); `LeadStageTransition`; `Task.create!`; `Telegram::PushToClient.send(user:, message:) -> Result(success?)`; `SegmentKeyboard` (Task 2).
- Produces: `ShowReports::Finalizer.new(report:, actor:, client:).call -> :confirmed | :already_done`; побочные эффекты: стадия → `show` (если была раньше), `lead.first_show_at ||= conducted_at`, `Task kind: call` «Обратная связь собственнику» с `due_at` = следующий день 11:00 MSK и `report.feedback_task_id`, пост в топик карточки, DM рассказчику с черновиком и кнопками `show_report:<id>:owner_push` (только если у собственника есть TG) / `owner_sent`, нудж сегмента если пуст. `Finalizer.feedback_due_at(conducted_at) -> Time`. `Finalizer#owner_reachable?`.

- [ ] **Step 1: Спека Finalizer (красная)**

```ruby
# spec/services/telegram/work_bot/show_reports/finalizer_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::ShowReports::Finalizer do
  let(:tg_client) do
    instance_double(Telegram::Client, send_message: { 'message_id' => 1 }, edit_message_text: { 'message_id' => 1 })
  end
  let(:agent)    { TelegramUser.create!(tg_user_id: 111, role: 'agent', first_name: 'Ирина', status: 'active', dm_chat_id: 111) }
  let(:director) { TelegramUser.create!(tg_user_id: 333, role: 'director', first_name: 'Оксана', status: 'active') }
  let(:owner)    { create(:user) }
  let(:property) { create(:property, address: 'Рязань, ул. Есенина, 12', owner_user: owner) }
  let(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'tg_dm', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1, anchor_thread_id: 17, anchor_message_id: 900,
                      assigned_to: agent, property: property, metadata: { 'name' => 'Анна' })
  end
  let(:conducted_at) { Time.zone.parse('2026-09-11 14:00') }
  let(:report) do
    ShowReport.create!(lead_event: lead, property: property, conducted_by: director, reported_by: agent,
                       conducted_at: conducted_at, source: 'voice', outcome: 'thinking', objections: ['кухня'],
                       owner_message: 'Добрый день! Провели показ.')
  end

  subject(:finalize) { described_class.new(report: report, actor: agent, client: tg_client).call }

  it 'подтверждает, двигает стадию в show и ставит first_show_at = conducted_at' do
    expect(finalize).to eq(:confirmed)
    expect(report.reload.status_confirmed?).to be(true)
    lead.reload
    expect(lead.current_stage).to eq('show')
    expect(lead.first_show_at).to eq(conducted_at)
  end

  it 'не откатывает стадию, если лид уже дальше show' do
    lead.update!(current_stage: 'contract')
    finalize
    expect(lead.reload.current_stage).to eq('contract')
  end

  it 'создаёт Task «обратная связь собственнику» до 11:00 следующего дня на рассказчика' do
    finalize
    task = Task.find(report.reload.feedback_task_id)
    expect(task.kind_call?).to be(true)
    expect(task.assignee).to eq(agent)
    expect(task.lead_event).to eq(lead)
    expect(task.title).to include('собственнику', 'Есенина')
    expect(task.due_at.in_time_zone('Europe/Moscow').strftime('%d.%m.%y %H:%M')).to eq('12.09.26 11:00')
  end

  it 'постит итог показа в топик карточки reply на якорь' do
    finalize
    expect(tg_client).to have_received(:send_message).with(
      a_string_including('Показ', '11.09.26', 'кухня'),
      hash_including(chat_id: -100_1, message_thread_id: 17, reply_to_message_id: 900)
    )
  end

  # Кнопки проверяем по захваченным вызовам: блок у have_received не вызывается.
  def owner_card_buttons
    calls = []
    allow(tg_client).to receive(:send_message) { |text, **opts| calls << [text, opts]; { 'message_id' => 1 } }
    finalize
    card = calls.find { |text, opts| opts[:chat_id] == 111 && text.include?('Добрый день! Провели показ.') }
    expect(card).not_to be_nil
    card[1][:reply_markup][:inline_keyboard].flatten.map { |b| b[:callback_data] }
  end

  it 'шлёт рассказчику черновик собственнику с кнопкой «отправил сам»; «в TG» — только если собственник в TG' do
    data = owner_card_buttons
    expect(data).to include("show_report:#{report.id}:owner_sent")
    expect(data).not_to include("show_report:#{report.id}:owner_push")
  end

  it 'с привязанным TG собственника появляется кнопка owner_push' do
    owner.update_columns(tg_user_id: 777_001)
    expect(owner_card_buttons).to include("show_report:#{report.id}:owner_push")
  end

  it 'нудж сегмента, если он пуст; без нуджа — если указан' do
    finalize
    expect(tg_client).to have_received(:send_message).with(a_string_including('сегмент'), hash_including(chat_id: 111))
  end

  it 'повторный вызов → :already_done без побочных эффектов' do
    finalize
    expect(described_class.new(report: report, actor: agent, client: tg_client).call).to eq(:already_done)
    expect(Task.where(lead_event: lead).count).to eq(1)
  end

  describe '.feedback_due_at' do
    it 'показ днём → завтра 11:00 МСК' do
      expect(described_class.feedback_due_at(Time.zone.parse('2026-09-11 14:00')).in_time_zone('Europe/Moscow').hour).to eq(11)
      expect(described_class.feedback_due_at(Time.zone.parse('2026-09-11 14:00')).to_date).to eq(Date.new(2026, 9, 12))
    end

    it 'показ после полуночи (ночной отчёт) → сегодня 11:00' do
      at = Time.find_zone('Europe/Moscow').parse('2026-09-12 00:30')
      expect(described_class.feedback_due_at(at).in_time_zone('Europe/Moscow').to_date).to eq(Date.new(2026, 9, 12))
    end
  end
end
```

- [ ] **Step 2: Finalizer**

```ruby
# app/services/telegram/work_bot/show_reports/finalizer.rb
# frozen_string_literal: true

module Telegram
  module WorkBot
    module ShowReports
      # BOTTLENECK — что происходит по нажатию [✅ Сохранить] в превью отчёта.
      #
      # Порядок не случаен: сначала БД (статус, стадия, задача) под локом, потом
      # Telegram (пост в топик, DM собственнику) вне лока — как в
      # TaskBatchConfirmCallback: TG-вызовы долгие и не должны держать строку.
      #
      # Задача «обратная связь собственнику до 11:00» — это I4 из ревью Шага 4:
      # самый жёсткий дедлайн регламента, единственный без таймера. Теперь у
      # него есть Task + Sla::TasksWatchdogJob.
      class Finalizer
        MOSCOW = 'Europe/Moscow'
        FEEDBACK_HOUR = 11

        # День в день, максимум — следующее утро до 11:00 (Шаг 4, этап 3.1).
        # Отчёт, надиктованный после полуночи, относится к «сегодня».
        def self.feedback_due_at(conducted_at)
          local = conducted_at.in_time_zone(MOSCOW)
          day = local.hour < FEEDBACK_HOUR ? local.to_date : local.to_date + 1
          Time.find_zone(MOSCOW).local(day.year, day.month, day.day, FEEDBACK_HOUR, 0)
        end

        def initialize(report:, actor:, client: Telegram::Client.new)
          @report = report
          @actor  = actor
          @client = client
          @lead   = report.lead_event
        end

        def call
          confirmed = false
          @report.with_lock do
            @report.reload
            return :already_done unless @report.status_pending_confirm?

            @report.confirm!
            stamp_first_show!
            create_feedback_task!
            confirmed = true
          end
          return :already_done unless confirmed

          move_stage!
          post_to_topic
          send_owner_draft
          nudge_segment if @lead.reload.segment.blank?
          :confirmed
        end

        def owner_reachable?
          owner_user&.tg_user_id.present?
        end

        private

        def owner_user
          @owner_user ||= @report.property&.owner_user
        end

        def stamp_first_show!
          return if @lead.first_show_at.present? && @lead.first_show_at <= @report.conducted_at

          @lead.update!(first_show_at: @report.conducted_at)
        end

        def create_feedback_task!
          task = ::Task.create!(
            lead_event: @lead,
            assignee: @report.reported_by,
            created_by: @actor,
            title: "Обратная связь собственнику: #{address}"[0, 255],
            kind: 'call',
            priority: 'high',
            status: 'open',
            due_at: self.class.feedback_due_at(@report.conducted_at),
            assigned_at: Time.current
          )
          @report.update!(feedback_task_id: task.id)
        end

        # Только вперёд: new/first_contact → show. Лид на contract/deal не трогаем.
        def move_stage!
          return unless ['new', 'first_contact'].include?(@lead.current_stage)

          result = LeadStageTransition.new(@lead, 'show', actor: @actor, client: @client).call
          Rails.logger.warn("[ShowReports::Finalizer] stage → show skipped: #{result.message}") unless result.success?
        rescue StandardError => e
          Rails.logger.warn("[ShowReports::Finalizer#move_stage!] #{e.class}: #{e.message}")
        end

        def post_to_topic
          return if @lead.anchor_message_id.blank?

          objections = @report.objections_list.any? ? @report.objections_list.join(', ') : 'без возражений'
          text = "🏠 <b>Показ #{Formatters::DateFormat.fmt_dt(@report.conducted_at)}</b> — " \
                 "#{escape(@report.conducted_by.display_name)} · #{@report.outcome_label}\n" \
                 "Возражения: #{escape(objections)}" \
                 "#{@report.next_step.present? ? "\nДальше: #{escape(@report.next_step)}" : ''}"
          @client.send_message(text, chat_id: @lead.tg_chat_id, message_thread_id: @lead.anchor_thread_id,
                                     reply_to_message_id: @lead.anchor_message_id, parse_mode: 'HTML')
        rescue Telegram::Client::Error => e
          Rails.logger.warn("[ShowReports::Finalizer#post_to_topic] #{e.message}")
        end

        def send_owner_draft
          reporter = @report.reported_by
          chat_id = reporter.dm_chat_id || reporter.tg_user_id
          return if chat_id.blank?

          due = Formatters::DateFormat.fmt_dt(self.class.feedback_due_at(@report.conducted_at))
          text = "✉️ <b>Собственнику до #{due}</b> (задача ##{@report.feedback_task_id}):\n\n" \
                 "#{escape(@report.owner_message)}\n\n" \
                 "<i>#{owner_reachable? ? 'Собственник в Telegram — можно отправить кнопкой.' : 'У собственника нет Telegram — скопируй и отправь сам.'}</i>"
          @client.send_message(text, chat_id: chat_id, parse_mode: 'HTML', reply_markup: owner_keyboard)
        rescue Telegram::Client::Error => e
          Rails.logger.warn("[ShowReports::Finalizer#send_owner_draft] #{e.message}")
        end

        def owner_keyboard
          row = []
          row << { text: '📤 Отправить в TG собственнику', callback_data: "show_report:#{@report.id}:owner_push" } if owner_reachable?
          row << { text: '✅ Отправил(а) сам(а)', callback_data: "show_report:#{@report.id}:owner_sent" }
          { inline_keyboard: [row] }
        end

        def nudge_segment
          reporter = @report.reported_by
          chat_id = reporter.dm_chat_id || reporter.tg_user_id
          return if chat_id.blank?

          @client.send_message(SegmentKeyboard.prompt_text, chat_id: chat_id, parse_mode: 'HTML',
                                                            reply_markup: SegmentKeyboard.for(@lead))
        rescue Telegram::Client::Error => e
          Rails.logger.warn("[ShowReports::Finalizer#nudge_segment] #{e.message}")
        end

        def address
          @report.property&.address.presence || "лид ##{@lead.id}"
        end

        def escape(text)
          text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
        end
      end
    end
  end
end
```

`Task#after_commit :refresh_dispatcher_digest` дёрнет `DispatcherDigestRefreshJob.perform_async` — в спеках Sidekiq в fake-режиме, ок.

Run: `bin/rb --db bundle exec rspec spec/services/telegram/work_bot/show_reports/finalizer_spec.rb` → PASS

- [ ] **Step 3: Спека callback'а (красная)**

```ruby
# spec/services/telegram/work_bot/callbacks/show_report_callback_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Callbacks::ShowReportCallback do
  let(:tg_client) do
    instance_double(Telegram::Client,
                    send_message: { 'message_id' => 1 }, edit_message_text: { 'message_id' => 1 },
                    answer_callback_query: { 'ok' => true })
  end
  let(:agent)    { TelegramUser.create!(tg_user_id: 111, role: 'agent', first_name: 'Ирина', status: 'active', dm_chat_id: 111) }
  let(:other)    { TelegramUser.create!(tg_user_id: 222, role: 'agent', first_name: 'Б', status: 'active', dm_chat_id: 222) }
  let!(:director) { TelegramUser.create!(tg_user_id: 333, role: 'director', first_name: 'Оксана', status: 'active') }
  let(:owner)    { create(:user, :tg_linked) }
  let(:property) { create(:property, owner_user: owner) }
  let(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'tg_dm', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1, anchor_message_id: 900,
                      assigned_to: agent, property: property)
  end
  let!(:report) do
    ShowReport.create!(lead_event: lead, property: property, conducted_by: director, reported_by: agent,
                       conducted_at: Time.current, source: 'voice', owner_message: 'Добрый день!',
                       preview_message_id: 505, preview_chat_id: 111)
  end

  def run(action, user: agent)
    data = "show_report:#{report.id}:#{action}"
    cb = { 'id' => 'cb-1', 'data' => data, 'from' => { 'id' => user.tg_user_id },
           'message' => { 'message_id' => 505, 'text' => 'превью', 'chat' => { 'id' => user.dm_chat_id, 'type' => 'private' } } }
    described_class.new(callback_query: cb, tg_user: user, args: data.split(':').drop(1), client: tg_client).call
  end

  it 'approve → подтверждён, превью помечено ✅, клавиатура снята' do
    run('approve')
    expect(report.reload.status_confirmed?).to be(true)
    expect(tg_client).to have_received(:edit_message_text)
      .with(a_string_including('Сохранено'), hash_including(message_id: 505, reply_markup: { inline_keyboard: [] }))
  end

  it 'cancel → отменён, превью помечено ✖️' do
    run('cancel')
    expect(report.reload.status_cancelled?).to be(true)
    expect(tg_client).to have_received(:edit_message_text).with(a_string_including('Отменено'), anything)
  end

  it 'toggle_conductor → показывающий меняется и превью перерисовывается целиком' do
    run('toggle_conductor')
    expect(report.reload.conducted_by).to eq(agent)
    expect(tg_client).to have_received(:edit_message_text)
      .with(a_string_including('Ирина'), hash_including(message_id: 505, reply_markup: hash_including(:inline_keyboard)))
  end

  it 'чужой пользователь → alert' do
    run('approve', user: other)
    expect(report.reload.status_pending_confirm?).to be(true)
    expect(tg_client).to have_received(:answer_callback_query).with('cb-1', hash_including(show_alert: true))
  end

  it 'approve дважды → второй раз «уже»' do
    run('approve')
    run('approve')
    expect(tg_client).to have_received(:answer_callback_query).with('cb-1', hash_including(text: a_string_including('Уже')))
  end

  context 'после подтверждения' do
    before { run('approve') }

    it 'owner_push шлёт собственнику через PushToClient, закрывает задачу, фиксирует канал' do
      push = instance_double(Telegram::PushToClient::Result, success?: true, error: nil)
      allow(Telegram::PushToClient).to receive(:send).and_return(push)
      run('owner_push')
      expect(Telegram::PushToClient).to have_received(:send).with(user: owner, message: a_string_including('Добрый день!'))
      report.reload
      expect(report.owner_notified_via).to eq('tg')
      expect(report.owner_notified_at).to be_present
      expect(Task.find(report.feedback_task_id).status_done?).to be(true)
    end

    it 'owner_push при отказе Telegram → alert, задача открыта' do
      push = instance_double(Telegram::PushToClient::Result, success?: false, error: 'bot was blocked')
      allow(Telegram::PushToClient).to receive(:send).and_return(push)
      run('owner_push')
      expect(report.reload.owner_notified_at).to be_nil
      expect(tg_client).to have_received(:answer_callback_query).with('cb-1', hash_including(show_alert: true))
    end

    it 'owner_sent закрывает задачу вручную (acked_method button)' do
      run('owner_sent')
      task = Task.find(report.reload.feedback_task_id)
      expect(task.status_done?).to be(true)
      expect(task.acked_method_button?).to be(true)
      expect(report.owner_notified_via).to eq('manual')
    end
  end
end
```

- [ ] **Step 4: Callback**

```ruby
# app/services/telegram/work_bot/callbacks/show_report_callback.rb
# frozen_string_literal: true

module Telegram
  module WorkBot
    module Callbacks
      # BOTTLENECK — кнопки под превью отчёта о показе и под черновиком собственнику.
      # callback_data: "show_report:<id>:approve|cancel|toggle_conductor|owner_push|owner_sent"
      #
      # Авторизация: рассказчик или руководитель. Не director_only — отчёт
      # подтверждает тот, кто его надиктовал.
      class ShowReportCallback < Base
        def handle
          report = ShowReport.find_by(id: @args[0].to_i)
          return ack('⚠️ Отчёт не найден', alert: true) if report.nil?
          return ack('🚫 Это не твой отчёт', alert: true) unless authorized?(report)

          case @args[1].to_s
          when 'approve'          then approve(report)
          when 'cancel'           then cancel(report)
          when 'toggle_conductor' then toggle_conductor(report)
          when 'owner_push'       then owner_push(report)
          when 'owner_sent'       then owner_sent(report)
          else ack('⚠️ Неизвестное действие', alert: true)
          end
        end

        private

        def authorized?(report)
          return false if tg_user.nil?

          report.reported_by_id == tg_user.id || tg_user.manager_or_director?
        end

        def approve(report)
          status = ShowReports::Finalizer.new(report: report, actor: tg_user, client: client).call
          return ack("ℹ️ Уже #{report.reload.status}", alert: true) if status == :already_done

          edit_preview(report, "\n\n✅ <b>Сохранено.</b> Задача собственнику ##{report.reload.feedback_task_id}.")
          ack('✅ Показ сохранён')
        end

        def cancel(report)
          return ack("ℹ️ Уже #{report.status}", alert: true) unless report.status_pending_confirm?

          report.cancel!
          edit_preview(report, "\n\n✖️ <b>Отменено</b>")
          ack('✖️ Отменено')
        end

        def toggle_conductor(report)
          return ack("ℹ️ Уже #{report.status} — показывающего не сменить", alert: true) unless report.status_pending_confirm?

          report.toggle_conductor!(reporter: report.reported_by, director: TelegramUser.directors.active.first)
          confirmer = ShowReports::Confirmer.new(report: report, client: client)
          client.edit_message_text(confirmer.preview_text, chat_id: report.preview_chat_id, message_id: report.preview_message_id,
                                                           parse_mode: 'HTML', reply_markup: confirmer.keyboard)
          ack("Показывал(а): #{report.conducted_by.display_name}")
        rescue Telegram::Client::Error => e
          raise unless e.message.match?(/not modified/i)

          ack('Без изменений')
        end

        def owner_push(report)
          return ack('ℹ️ Собственник уже уведомлён', alert: true) if report.owner_notified_at.present?

          owner = report.property&.owner_user
          return ack('⚠️ У собственника нет Telegram — отправь сам', alert: true) if owner&.tg_user_id.blank?

          # BOTTLENECK — собственнику не шлём в тихие часы. Показы вечерние,
          # отчёт часто в 21:30, а регламент требует обратную связь «день в день
          # до 11:00» — то есть утром. Кнопка остаётся активной, задача с due_at
          # 11:00 уже стоит (см. #approve), состояние не теряется: сотруднику
          # просто говорят, когда нажимать. Авто-отправки по таймеру здесь нет
          # намеренно — правило «собственнику ничего без кнопки» сильнее удобства.
          if Telegram::WorkBot::QuietHours.active?
            return ack(
              "🌙 Тихие часы — собственнику отправим утром. Нажми эту же кнопку после " \
              "#{Formatters::DateFormat.fmt_dt(Telegram::WorkBot::QuietHours.next_window_start)}",
              alert: true
            )
          end

          result = Telegram::PushToClient.send(user: owner, message: report.owner_message.to_s)
          return ack("⚠️ Не доставлено: #{result.error.to_s.truncate(80)}", alert: true) unless result.success?

          mark_owner_notified(report, 'tg')
          ack('📤 Отправлено собственнику')
        end

        def owner_sent(report)
          return ack('ℹ️ Уже отмечено', alert: true) if report.owner_notified_at.present?

          mark_owner_notified(report, 'manual')
          ack('✅ Задача закрыта')
        end

        def mark_owner_notified(report, via)
          report.update!(owner_notified_at: Time.current, owner_notified_via: via)
          ::Task.find_by(id: report.feedback_task_id)&.mark_completed!(acked_method: 'button')
          strike_owner_card("\n\n✅ <b>Собственник уведомлён</b> #{Formatters::DateFormat.fmt_dt(report.owner_notified_at)}")
        end

        def edit_preview(report, suffix)
          return if report.preview_message_id.blank?

          original = callback_query.dig('message', 'text').to_s
          client.edit_message_text("#{original}#{suffix}", chat_id: report.preview_chat_id, message_id: report.preview_message_id,
                                                            parse_mode: 'HTML', reply_markup: { inline_keyboard: [] })
        rescue Telegram::Client::Error => e
          Rails.logger.warn("[ShowReportCallback#edit_preview] #{e.message}")
        end

        # Карточка с черновиком — то сообщение, под которым нажали кнопку.
        def strike_owner_card(suffix)
          msg = callback_query['message']
          return if msg.blank?

          client.edit_message_text("#{msg['text']}#{suffix}", chat_id: msg.dig('chat', 'id'), message_id: msg['message_id'],
                                                               parse_mode: 'HTML', reply_markup: { inline_keyboard: [] })
        rescue Telegram::Client::Error => e
          Rails.logger.warn("[ShowReportCallback#strike_owner_card] #{e.message}")
        end
      end
    end
  end
end
```

Зарегистрировать в `callbacks_router.rb` `PREFIX_MAP`: `'show_report' => 'Telegram::WorkBot::Callbacks::ShowReportCallback',`.

- [ ] **Step 5: Спека тихих часов для собственника**

В спеку callback'а (Step 3) добавить:

```ruby
  describe 'тихие часы' do
    it 'в 22:30 МСК собственнику не уходит, кнопка остаётся' do
      travel_to Time.zone.parse('2026-09-11 22:30') do
        expect(Telegram::PushToClient).not_to receive(:send)
        described_class.new(callback_query: cb("show_report:#{report.id}:owner_push"),
                            tg_user: agent, args: [report.id.to_s, 'owner_push'],
                            client: tg_client).call
      end
      expect(report.reload.owner_notified_at).to be_nil
    end

    it 'в 10:00 МСК уходит' do
      travel_to Time.zone.parse('2026-09-11 10:00') do
        allow(Telegram::PushToClient).to receive(:send)
          .and_return(Telegram::PushToClient::Result.new(success: true))
        described_class.new(callback_query: cb("show_report:#{report.id}:owner_push"),
                            tg_user: agent, args: [report.id.to_s, 'owner_push'],
                            client: tg_client).call
      end
      expect(report.reload.owner_notified_at).to be_present
    end
  end
```

Хелпер в спеке называется `run(action)` (а не `cb(...)`), `Telegram::PushToClient::Result` — реальный Struct из `app/services/telegram/push_to_client.rb`, стабить им, **не литеральным хэшем** (см. Global Constraints). `travel_to` подключён глобально в `rails_helper` (Iter 61).

⚠️ **Вся спека callback'а обязана фиксировать время**, а не только примеры про тихие часы. Поймано на исполнении 12.09.26: `owner_push` теперь уважает `QuietHours`, поэтому без `before { travel_to(...) }` на весь `describe` примеры про успешную отправку собственнику падали бы при любом прогоне CI между 21:00 и 07:00 МСК — то есть спека была бы зелёной днём и красной ночью. Ставить `travel_to` на дневной момент в общий `before`, а ночные примеры переводить время внутри себя.

Run: `bin/rb --db bundle exec rspec spec/services/telegram/work_bot/callbacks/show_report_callback_spec.rb`
Expected: PASS

- [ ] **Step 6: Счётчик показов на карточке** — в `lead_announcer.rb#format_card_text` после строки сегмента (Task 2):

```ruby
        shows = @lead.show_reports.status_confirmed.count
        lines << "🏠 показов: #{shows}" if shows.positive?
```

- [ ] **Step 7: Прогнать, линтер, коммит**

```bash
bin/rb --db bundle exec rspec spec/services/telegram/work_bot/show_reports spec/services/telegram/work_bot/callbacks/show_report_callback_spec.rb spec/services/telegram/work_bot/callbacks/segment_callback_spec.rb
bin/rb bundle exec rubocop app/services/telegram/work_bot
git add app/services/telegram/work_bot spec/services/telegram/work_bot
git commit -m "feat(shows): Finalizer + ShowReportCallback — подтверждение показа, стадия, задача до 11:00, черновик собственнику

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: Входы — голосовое агента и `/show`

**Files:**
- Modify: `app/services/telegram/work_bot/voice_intent_branch.rb` (промпт, `#call`)
- Modify: `app/services/telegram/work_bot/voice_intake_processor.rb` (`#call` гейт, `#process_voice`, новые `#handle_show_report`, `#handle_task_batch`)
- Create: `app/services/telegram/work_bot/commands/show.rb`
- Modify: `router.rb` `COMMANDS`, `config/telegram_bot_commands.yml`, `commands/help.rb` `ENTRIES`
- Test: `spec/services/telegram/work_bot/voice_intent_branch_spec.rb` (дополнить), `spec/services/telegram/work_bot/voice_intake_processor_spec.rb` (новый), `spec/services/telegram/work_bot/commands/show_spec.rb`

**Interfaces:**
- Consumes: `ShowReports::Intake.new(reporter:, transcript_raw:, transcript_redacted:, source:, chat_id:, lead:, client:).call -> Result(ok, report, message)` (Task 6); `VoiceTranscriber::Result#text/#raw['text']`.
- Produces: `VoiceIntentBranch.call(text) -> :query | :task_batch | :show_report` (`RICH_KINDS = %w[query show_report]`); `VoiceIntakeProcessor` принимает голос от любого активного сотрудника: директор — все три интента, агент — только `:show_report`; статусы `:show_report`, `:show_report_failed`; команда `/show <lead_id> <текст>` (DM) или `/show <текст>` reply на карточку.

- [ ] **Step 1: Дополнить спеку интента (красные примеры)**

В `spec/services/telegram/work_bot/voice_intent_branch_spec.rb` внутри `describe '.call'`:

```ruby
    it 'возвращает :show_report при kind=show_report и confidence>=0.7' do
      client = StubOmniClientForBranch.new(content: { kind: 'show_report', confidence: 0.9 }.to_json)
      expect(described_class.call('показ на Есенина прошёл, кухня не понравилась', client: client)).to eq(:show_report)
    end

    it 'show_report с низкой confidence → :task_batch (safer default)' do
      client = StubOmniClientForBranch.new(content: { kind: 'show_report', confidence: 0.4 }.to_json)
      expect(described_class.call('что-то про показ', client: client)).to eq(:task_batch)
    end
```

- [ ] **Step 2: Интент** — в `voice_intent_branch.rb`:

Константа и `#call`:

```ruby
      RICH_KINDS = ['query', 'show_report'].freeze

      # @return [Symbol] :query, :show_report или :task_batch
      def call
        return :task_batch if @transcript.empty?

        res = @client.complete(
          [{ role: 'system', content: SYSTEM_PROMPT }, { role: 'user', content: @transcript }],
          chain: :staff_analysis, response_format: { type: 'json_object' }, temperature: 0.1, max_tokens: 80
        )
        parsed = JSON.parse(res[:content].to_s)
        kind = parsed['kind'].to_s
        conf = parsed['confidence'].to_f

        if RICH_KINDS.include?(kind) && conf >= CONFIDENCE_THRESHOLD
          Rails.logger.info("[VoiceIntentBranch] kind=#{kind} confidence=#{conf} transcript=#{@transcript.truncate(80).inspect}")
          kind.to_sym
        else
          Rails.logger.info("[VoiceIntentBranch] kind=task_batch confidence=#{conf} llm_kind=#{kind.inspect}")
          :task_batch
        end
      rescue StandardError => e
        Rails.logger.warn("[VoiceIntentBranch] fallback to task_batch: #{e.class} #{e.message}")
        :task_batch
      end
```

В `SYSTEM_PROMPT` заменить строку формата на `{"kind": "query"|"task_batch"|"show_report", "confidence": <0.0..1.0>}` и добавить перед «Если непонятно»:

```
        show_report — рассказ о ПРОВЕДЁННОМ показе квартиры: что сказали покупатели, что не понравилось,
        назвали ли цену, что дальше. Нет адресата-сотрудника, нет поручения. Примеры show_report:
          • "показ на Есенина прошёл, им не понравилась кухня, берут паузу до пятницы"
          • "показала двушку на Ленина, покупатели предложили пять двести, хотят второй показ"
          • "Оксана показала дом в Солотче, отказались, далеко от города"
```

Run: `bin/rb --db bundle exec rspec spec/services/telegram/work_bot/voice_intent_branch_spec.rb` → PASS (9 примеров)

- [ ] **Step 3: Спека процессора голоса (новый файл, красная)**

```ruby
# spec/services/telegram/work_bot/voice_intake_processor_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::VoiceIntakeProcessor do
  let(:tg_client) do
    instance_double(Telegram::Client, send_message: { 'message_id' => 10 }, edit_message_text: { 'message_id' => 10 })
  end
  let(:agent)    { TelegramUser.create!(tg_user_id: 111, role: 'agent', first_name: 'Ирина', status: 'active', dm_chat_id: 111) }
  let(:director) { TelegramUser.create!(tg_user_id: 333, role: 'director', first_name: 'Оксана', status: 'active', dm_chat_id: 333) }
  let(:transcription) do
    Telegram::WorkBot::VoiceTranscriber::Result.new(text: 'показ прошёл, кухня не понравилась', confidence: -0.2,
                                                     duration_sec: 5, model: 'stub', raw: { 'text' => 'показ прошёл, кухня не понравилась' },
                                                     low_confidence: false, hallucination: false, error: nil)
  end
  let(:intake_ok) { Telegram::WorkBot::ShowReports::Intake::Result.new(ok: true, report: instance_double(ShowReport, id: 7)) }

  before do
    allow(Telegram::WorkBot::VoiceTranscriber).to receive(:call).and_return(transcription)
    allow(Nextcloud::VoiceArchiver).to receive(:call)
  end

  def msg_for(user)
    { 'message_id' => 1, 'chat' => { 'id' => user.dm_chat_id, 'type' => 'private' },
      'from' => { 'id' => user.tg_user_id }, 'voice' => { 'file_id' => 'F1' } }
  end

  it 'агент: голос идёт в ShowReports::Intake без классификации интента' do
    intake = instance_double(Telegram::WorkBot::ShowReports::Intake, call: intake_ok)
    allow(Telegram::WorkBot::ShowReports::Intake).to receive(:new).and_return(intake)
    expect(Telegram::WorkBot::VoiceIntentBranch).not_to receive(:call)

    expect(described_class.new(msg_for(agent), client: tg_client).call).to eq(:show_report)
    expect(Telegram::WorkBot::ShowReports::Intake).to have_received(:new)
      .with(hash_including(reporter: agent, source: 'voice', transcript_raw: 'показ прошёл, кухня не понравилась'))
  end

  it 'директор: интент show_report → Intake' do
    allow(Telegram::WorkBot::VoiceIntentBranch).to receive(:call).and_return(:show_report)
    intake = instance_double(Telegram::WorkBot::ShowReports::Intake, call: intake_ok)
    allow(Telegram::WorkBot::ShowReports::Intake).to receive(:new).and_return(intake)
    expect(described_class.new(msg_for(director), client: tg_client).call).to eq(:show_report)
  end

  it 'Intake вернул ok:false → текст подсказки в edit «Слушаю…»' do
    intake = instance_double(Telegram::WorkBot::ShowReports::Intake,
                             call: Telegram::WorkBot::ShowReports::Intake::Result.new(ok: false, message: '🤔 Не понял лид'))
    allow(Telegram::WorkBot::ShowReports::Intake).to receive(:new).and_return(intake)
    expect(described_class.new(msg_for(agent), client: tg_client).call).to eq(:show_report_failed)
    expect(tg_client).to have_received(:edit_message_text).with(a_string_including('Не понял лид'), hash_including(message_id: 10))
  end

  it 'неактивный сотрудник → отказ' do
    agent.update!(status: 'inactive')
    expect(described_class.new(msg_for(agent), client: tg_client).call).to eq(:refused)
  end

  it 'директор с интентом task_batch и pending TaskBatch → :refused_pending (старое поведение сохранено)' do
    allow(Telegram::WorkBot::VoiceIntentBranch).to receive(:call).and_return(:task_batch)
    TaskBatch.create!(created_by: director, source: 'voice', status: 'pending_confirm', parsed_payload: { 'tasks' => [] })
    expect(described_class.new(msg_for(director), client: tg_client).call).to eq(:refused_pending)
  end
end
```

- [ ] **Step 4: Процессор голоса** — в `voice_intake_processor.rb`:

В `#call` заменить

```ruby
        return refuse_non_director(tg_user) unless tg_user.can_voice_distribute?
        ...
        pending = TaskBatch.pending.where(created_by: tg_user).order(created_at: :desc).first
        return refuse_pending_batch(pending) if pending
```

на

```ruby
        # BOTTLENECK — голос принимаем от любого активного сотрудника: агент
        # диктует отчёт о показе. Распределение задач по-прежнему только директор
        # (см. handle_task_batch).
        return refuse_inactive(tg_user) unless tg_user.status == 'active'
```

`process_voice` после проверок транскрипции:

```ruby
        # Агенту голосом доступен только отчёт о показе — классификатор не нужен,
        # и ошибочный «task_batch» от агента невозможен по построению.
        intent = tg_user.can_voice_distribute? ? Telegram::WorkBot::VoiceIntentBranch.call(transcription.text) : :show_report

        case intent
        when :query       then handle_query(tg_user, transcription)
        when :show_report then handle_show_report(tg_user, transcription)
        else                   handle_task_batch(tg_user, transcription)
        end
```

Новые методы (старое тело task_batch-ветки переезжает в `handle_task_batch` вместе с проверкой pending):

```ruby
      def handle_task_batch(tg_user, transcription)
        pending = TaskBatch.pending.where(created_by: tg_user).order(created_at: :desc).first
        return refuse_pending_batch(pending) if pending

        extraction = Telegram::WorkBot::TaskExtractor.call(
          transcript: transcription.raw['text'].to_s, staff: TelegramUser.assignable.to_a, now: Time.current
        )
        return extract_failed(extraction) unless extraction.success?
        return no_tasks(extraction) if extraction.tasks.empty?

        batch = create_batch(tg_user, transcription, extraction)
        Telegram::WorkBot::TaskBatchConfirmer.new(batch: batch, client: @client).call
        archive_voice_to_nc(tg_user, transcription.text, batch.id)
        :dispatched
      end

      # BOTTLENECK — отчёт о показе. Превью шлёт Intake; здесь только ошибки
      # редактируем в «🎙 Слушаю…» и архивируем голос в NC (как query/task_batch).
      def handle_show_report(tg_user, transcription)
        result = Telegram::WorkBot::ShowReports::Intake.new(
          reporter: tg_user,
          transcript_raw: transcription.raw['text'].to_s,
          transcript_redacted: transcription.text,
          source: 'voice',
          chat_id: @msg.dig('chat', 'id'),
          client: @client
        ).call
        archive_voice_to_nc(tg_user, transcription.text, nil)
        if result.ok
          edit_ack('✅ Распознал — превью отчёта ниже, проверь и сохрани.')
          return :show_report
        end

        edit_ack(result.message)
        :show_report_failed
      end

      def refuse_inactive(_tg_user)
        reply('🚫 Учётка неактивна — обратись к руководителю.')
        :refused
      end
```

`refuse_non_director` удалить (больше не вызывается).

Run: `bin/rb --db bundle exec rspec spec/services/telegram/work_bot/voice_intake_processor_spec.rb spec/services/telegram/work_bot/voice_intent_branch_spec.rb` → PASS

- [ ] **Step 5: Команда `/show` — спека (красная)**

```ruby
# spec/services/telegram/work_bot/commands/show_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Commands::Show do
  let(:tg_client) { instance_double(Telegram::Client, send_message: { 'message_id' => 1 }) }
  let(:agent) { TelegramUser.create!(tg_user_id: 111, role: 'agent', first_name: 'Ирина', status: 'active', dm_chat_id: 111) }
  let!(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'tg_dm', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1, anchor_message_id: 900, assigned_to: agent)
  end
  let(:intake) { instance_double(Telegram::WorkBot::ShowReports::Intake) }

  before { allow(Telegram::WorkBot::ShowReports::Intake).to receive(:new).and_return(intake) }

  def run(args, msg_overrides = {})
    msg = { 'chat' => { 'id' => 111, 'type' => 'private' }, 'from' => { 'id' => 111 }, 'message_id' => 5,
            'text' => "/show #{args}" }.merge(msg_overrides)
    described_class.new(message: msg, args: args, tg_user: agent, client: tg_client).send(:handle)
  end

  it '/show <id> <текст> → Intake с явным лидом и source text; текст маскируется' do
    allow(intake).to receive(:call).and_return(Telegram::WorkBot::ShowReports::Intake::Result.new(ok: true))
    run("#{lead.id} показ прошёл, звонить +79001234567")
    expect(Telegram::WorkBot::ShowReports::Intake).to have_received(:new).with(
      hash_including(lead: lead, source: 'text', reporter: agent,
                     transcript_raw: 'показ прошёл, звонить +79001234567',
                     transcript_redacted: a_string_excluding('79001234567'))
    )
  end

  it 'reply на карточку без id тоже работает' do
    allow(intake).to receive(:call).and_return(Telegram::WorkBot::ShowReports::Intake::Result.new(ok: true))
    run('кухня не понравилась', 'chat' => { 'id' => -100_1, 'type' => 'supergroup' }, 'reply_to_message' => { 'message_id' => 900 })
    expect(Telegram::WorkBot::ShowReports::Intake).to have_received(:new).with(hash_including(lead: lead))
  end

  it 'без текста — формат' do
    run(lead.id.to_s)
    expect(tg_client).to have_received(:send_message).with(a_string_including('Формат'), anything)
    expect(Telegram::WorkBot::ShowReports::Intake).not_to have_received(:new)
  end

  it 'Intake ok:false → его сообщение в ответ' do
    allow(intake).to receive(:call).and_return(Telegram::WorkBot::ShowReports::Intake::Result.new(ok: false, message: 'неподтверждённый #3'))
    run("#{lead.id} текст отчёта")
    expect(tg_client).to have_received(:send_message).with(a_string_including('неподтверждённый #3'), anything)
  end
end
```

`a_string_excluding` — если матчера нет в проекте, заменить на `satisfy { |s| !s.include?('79001234567') }`.

- [ ] **Step 6: Команда**

```ruby
# app/services/telegram/work_bot/commands/show.rb
# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # BOTTLENECK — `/show <текст>` reply на карточку или `/show <lead_id> <текст>` в DM:
      # отчёт о показе текстом, когда голосовое неудобно (в машине с клиентом,
      # в шумном подъезде). Лид задан явно — LLM его не угадывает.
      class Show < Base
        def handle
          lead = resolve_lead!
          return reply(lead_not_found_hint('show 12 показ прошёл, кухня не понравилась')) unless lead

          text = @args.to_s.strip
          if text.blank?
            return reply('Формат: <code>/show &lt;lead_id&gt; &lt;что сказали покупатели&gt;</code> в личке или ' \
                         '<code>/show &lt;текст&gt;</code> reply на карточку.')
          end

          result = ShowReports::Intake.new(
            reporter: tg_user,
            transcript_raw: text,
            transcript_redacted: Privacy::TranscriptRedactor.call(text),
            source: 'text',
            chat_id: message.dig('chat', 'id'),
            lead: lead,
            client: client
          ).call
          return reply(result.message) unless result.ok

          reply('✅ Принял, превью отчёта — в личке.') if message.dig('chat', 'type') != 'private'
        end
      end
    end
  end
end
```

Регистрация: `router.rb` `'/show' => Commands::Show,`; yml — `- { cmd: show, tier: staff, group: true, desc: 'Отчёт о показе текстом: /show <lead_id> что сказали покупатели' }`; `help.rb` `ENTRIES` — `/show` — «Отчёт о показе текстом (или просто голосовое боту в личку)».

- [ ] **Step 7: Спека диспетчера и реестров команд**

Две вещи, которые до сверки 12.09.26 не были закрыты ничем, а этот план их меняет: порядок веток в `Telegram::InboundProcessor` (голос теперь принимается не только от директора) и три реестра команд, в которые надо попасть одновременно.

Заодно поправить устаревший комментарий над голосовой веткой в `inbound_processor.rb` («voice от директора АН в DM боту») — теперь это «voice от активного сотрудника: директору — задачи/вопрос/отчёт, остальным — отчёт о показе».

```ruby
# spec/services/telegram/inbound_processor_spec.rb
# frozen_string_literal: true

require 'rails_helper'

# BOTTLENECK — порядок веток диспетчера есть фактическая спецификация
# приоритетов, и до этого файла он не был закрыт ни одним тестом. План меняет
# гейт голосовой ветки, поэтому оставляет после себя тест, который поймает
# и перестановку веток, и случайный возврат старого гейта.
RSpec.describe Telegram::InboundProcessor do
  let!(:agent) do
    TelegramUser.create!(tg_user_id: 501, role: 'agent', first_name: 'Оксана',
                         is_manager: false, status: 'active', dm_chat_id: 501)
  end

  def voice_update(from_id:)
    { 'update_id' => rand(1..10**9),
      'message' => { 'message_id' => 31, 'from' => { 'id' => from_id },
                     'chat' => { 'id' => from_id, 'type' => 'private' },
                     'voice' => { 'file_id' => 'AwACAgIAAx' } } }
  end

  it 'голос агента в личке попадает в VoiceIntakeProcessor, а не в клиентскую ветку' do
    processor = instance_double(Telegram::WorkBot::VoiceIntakeProcessor, call: :show_report)
    expect(Telegram::WorkBot::VoiceIntakeProcessor).to receive(:new).and_return(processor)
    expect(Telegram::ClientBot::TextIntakeProcessor).not_to receive(:new)

    expect(described_class.new(voice_update(from_id: 501)).call).to eq(:show_report)
  end

  it 'повторный update_id не обрабатывается второй раз' do
    update = voice_update(from_id: 501)
    allow(Telegram::WorkBot::VoiceIntakeProcessor).to receive(:new)
      .and_return(instance_double(Telegram::WorkBot::VoiceIntakeProcessor, call: :show_report))

    expect(described_class.new(update).call).to eq(:show_report)
    expect(described_class.new(update).call).to eq(:duplicate)
  end
end
```

```ruby
# spec/services/telegram/work_bot/command_registries_spec.rb
# frozen_string_literal: true

require 'rails_helper'

# BOTTLENECK — команда живёт в трёх реестрах: Router::COMMANDS (исполнение),
# telegram_bot_commands.yml (нативное «/»-меню) и Help::ENTRIES (/help).
# Промах в любом из них не ломает ничего заметного: команда просто не видна
# в меню или не упомянута в справке — и ей не пользуются. Спека закрывает
# только команды этого плана: исторический дрейф по остальным не её дело.
RSpec.describe 'реестры команд show-воронки' do
  SHOW_COMMANDS = %w[segment show objections bargain stage].freeze

  let(:yaml_cmds) do
    YAML.load_file(Rails.root.join('config/telegram_bot_commands.yml'))
        .fetch('commands').map { |c| c.fetch('cmd') }
  end
  let(:help_cmds) do
    Telegram::WorkBot::Commands::Help::ENTRIES.map { |cmd, _, _| cmd.to_s.delete_prefix('/') }
  end
  let(:router_cmds) do
    Telegram::WorkBot::Router::COMMANDS.keys.map { |k| k.to_s.delete_prefix('/') }
  end

  SHOW_COMMANDS.each do |cmd|
    it "/#{cmd} зарегистрирована во всех трёх реестрах" do
      expect(router_cmds).to include(cmd)
      expect(yaml_cmds).to include(cmd)
      expect(help_cmds).to include(cmd)
    end
  end

  it 'в YAML нет дублей — setMyCommands падает на повторах' do
    expect(yaml_cmds).to eq(yaml_cmds.uniq)
  end
end
```

Список команд в спеке растёт вместе с ними: здесь `%w[segment show stage]`, `/objections` добавляется в Task 9, `/bargain` — в Task 11. Так каждый коммит остаётся зелёным, и спека не ждёт кода из будущего стека (решено на исполнении 12.09.26).

Run: `bin/rb --db bundle exec rspec spec/services/telegram/inbound_processor_spec.rb spec/services/telegram/work_bot/command_registries_spec.rb`
Expected: PASS

- [ ] **Step 8: Прогнать, линтер, коммит, PR стека B**

```bash
bin/rb --db bundle exec rspec spec/services/telegram/work_bot spec/models/show_report_spec.rb
bin/rb bundle exec rubocop app/services/telegram/work_bot config/telegram_bot_commands.yml
git add app/services/telegram/work_bot config/telegram_bot_commands.yml spec/services/telegram/work_bot
git commit -m "feat(shows): голосовой отчёт о показе от агента + /show текстом — третий интент VoiceIntentBranch

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

Ручная проверка на живом боте (`bin/rb --web up`, webhook через CF Worker или `TELEGRAM_POLLING_MODE=true`): агент шлёт голосовое → «🎙 Слушаю…» → превью → ✅ → в топике карточки появляется «🏠 Показ …», в DM — черновик собственнику, задача в `/dashboard` → просрочки после 11:00.

---
### Task 9: `/objections`, `Kpi::ShowFunnel` и блок воронки показов в понедельничной сводке

**Files:**
- Create: `app/services/kpi/show_funnel.rb`
- Create: `app/services/telegram/work_bot/commands/objections.rb`
- Modify: `app/services/telegram/work_bot/weekly_summary_job.rb` (добавить блок в сборку текста отчёта — в метод, где сейчас вызывается `llm_cost_report`)
- Modify: `router.rb` `COMMANDS`, `config/telegram_bot_commands.yml`, `commands/help.rb` `ENTRIES`
- Test: `spec/services/kpi/show_funnel_spec.rb`, `spec/services/telegram/work_bot/commands/objections_spec.rb`, `spec/services/telegram/work_bot/weekly_summary_job_spec.rb` (дополнить одним примером)

**Interfaces:**
- Consumes: `ShowReport.confirmed_in/for_property/#objections_list/#conducted_by_director?`, `LeadEvent.real.shown`, `#contract_at`, `#segment`, `Property.in_advertising`, `#published_at`.
- Produces: `Kpi::ShowFunnel.new(week: Range, cohort: Range).call -> Kpi::ShowFunnel::Result(week_shows, matrix, objects, unreported)`; `Kpi::ShowFunnel#render_html -> String`; `Kpi::ShowFunnel.objections_summary(property:) -> Hash(shows:, objections: [[tag, count]], outcomes: Hash, offered_prices: [])`. Команда `/objections` (reply на карточку или `/objections <lead_id>`).

Определения (зафиксировать комментарием в коде — в проекте уже четыре разных «конверсии»):
- **Показ** — `ShowReport.status_confirmed`, дата — `conducted_at`.
- **Когорта** — `LeadEvent.real` с `first_show_at` в окне `cohort` (по умолчанию 8 недель до конца отчётной недели).
- **Конверсия показ→договор** — доля лидов когорты с `contract_at IS NOT NULL`. Считается в ячейке `segment × кто показывал` (`кто показывал` = роль `conducted_by` первого подтверждённого показа лида: `руководитель` / `агент`). Сегмент `nil` → строка «не указан» — отдельно, чтобы было видно, сколько данных выпало.
- **Объекты:** без показов 30 дней среди `Property.in_advertising`; медиана дней от `published_at` до первого показа (по объектам с первым показом в когорте); объекты с ≥3 показами и без лида с `contract_at`.
- **Показы без отчёта** — лиды с `first_show_at` старше 24 ч и без подтверждённого `ShowReport`.

- [ ] **Step 1: Спека `Kpi::ShowFunnel` (красная)**

```ruby
# spec/services/kpi/show_funnel_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Kpi::ShowFunnel do
  let(:agent)    { TelegramUser.create!(tg_user_id: 111, role: 'agent', first_name: 'Ирина', status: 'active') }
  let(:director) { TelegramUser.create!(tg_user_id: 333, role: 'director', first_name: 'Оксана', status: 'active') }
  let(:week)   { Time.zone.parse('2026-09-07 00:00')..Time.zone.parse('2026-09-13 23:59:59') }
  let(:cohort) { Time.zone.parse('2026-07-20 00:00')..week.end }

  # «30 дней», «24 часа» считаются от Time.current — замораживаем, иначе спека протухнет.
  around { |ex| travel_to(Time.zone.parse('2026-09-14 10:00')) { ex.run } }

  def lead!(segment:, first_show_at:, contract_at: nil, property: nil, staff_test: false)
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'tg_dm', current_stage: contract_at ? 'contract' : 'show',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1, assigned_to: agent, segment: segment,
                      first_show_at: first_show_at, contract_at: contract_at, property: property, staff_test: staff_test)
  end

  def show!(lead, by:, at: lead.first_show_at, status: 'confirmed', objections: [], price: nil)
    ShowReport.create!(lead_event: lead, property: lead.property, conducted_by: by, reported_by: agent,
                       conducted_at: at, source: 'voice', status: status, objections: objections, offered_price: price)
  end

  describe '#call' do
    it 'матрица сегмент × кто показывал: показы и договоры считаются внутри ячейки' do
      l1 = lead!(segment: 'cold', first_show_at: week.begin + 1.day)
      l2 = lead!(segment: 'cold', first_show_at: week.begin + 2.days, contract_at: week.begin + 4.days)
      l3 = lead!(segment: 'cash', first_show_at: week.begin + 2.days, contract_at: week.begin + 5.days)
      show!(l1, by: agent); show!(l2, by: agent); show!(l3, by: director)

      res = described_class.new(week: week, cohort: cohort).call
      expect(res.week_shows).to eq(3)
      expect(res.matrix['cold']['агент']).to eq(shows: 2, contracts: 1)
      expect(res.matrix['cash']['руководитель']).to eq(shows: 1, contracts: 1)
      expect(res.matrix['cold']['руководитель']).to eq(shows: 0, contracts: 0)
    end

    it 'nil-сегмент идёт отдельной строкой «не указан», staff_test не считается' do
      lead!(segment: nil, first_show_at: week.begin + 1.day).then { |l| show!(l, by: director) }
      lead!(segment: 'cash', first_show_at: week.begin + 1.day, staff_test: true).then { |l| show!(l, by: director) }
      res = described_class.new(week: week, cohort: cohort).call
      expect(res.matrix['не указан']['руководитель'][:shows]).to eq(1)
      expect(res.matrix.dig('cash', 'руководитель', :shows).to_i).to eq(0)
    end

    it 'pending отчёт — не показ; лид с first_show_at без подтверждённого отчёта — «без отчёта»' do
      l = lead!(segment: 'cold', first_show_at: week.begin + 1.day)
      show!(l, by: agent, status: 'pending_confirm')
      res = described_class.new(week: week, cohort: cohort).call
      expect(res.week_shows).to eq(0)
      expect(res.unreported).to eq(1)
    end

    it 'объекты: без показов 30 дней, медиана дней до первого показа, ≥3 показов без договора' do
      idle  = create(:property, :on_site, in_ad: true, deal_state: 'ad', published_at: 40.days.ago)
      quick = create(:property, :on_site, in_ad: true, deal_state: 'ad', published_at: week.begin - 10.days)
      stuck = create(:property, :on_site, in_ad: true, deal_state: 'ad', published_at: week.begin - 20.days)

      lq = lead!(segment: 'cash', first_show_at: week.begin, property: quick); show!(lq, by: director)
      # stuck: три показа по 10 дней после публикации → медиана по объектам [10, 10] = 10;
      # последний показ 17 дней назад → объект не «без показов 30 дней».
      3.times do |i|
        l = lead!(segment: 'cold', first_show_at: week.begin - 10.days + i.hours, property: stuck)
        show!(l, by: agent)
      end

      res = described_class.new(week: week, cohort: cohort).call
      expect(res.objects[:no_shows_30d]).to include(idle.id)
      expect(res.objects[:no_shows_30d]).not_to include(quick.id, stuck.id)
      expect(res.objects[:median_days_to_first_show]).to eq(10)
      expect(res.objects[:stuck]).to eq([stuck.id])
    end
  end

  describe '#render_html' do
    it 'содержит матрицу, объекты и предупреждение про сравнение внутри сегмента' do
      l = lead!(segment: 'cold', first_show_at: week.begin + 1.day); show!(l, by: agent)
      html = described_class.new(week: week, cohort: cohort).render_html
      expect(html).to include('Показы', 'Холодный', 'агент', 'внутри сегмента')
    end
  end

  describe '.objections_summary' do
    it 'агрегирует теги и исходы по объекту' do
      property = create(:property)
      l1 = lead!(segment: 'cold', first_show_at: 3.days.ago, property: property)
      l2 = lead!(segment: 'cash', first_show_at: 2.days.ago, property: property)
      show!(l1, by: agent, objections: ['маленькая кухня', 'первый этаж'])
      show!(l2, by: director, objections: ['Маленькая кухня'], price: 5_200_000)
      s = described_class.objections_summary(property: property)
      expect(s[:shows]).to eq(2)
      expect(s[:objections].first).to eq(['маленькая кухня', 2])
      expect(s[:offered_prices]).to eq([5_200_000])
    end
  end
end
```

Если у фабрики `:property` нет атрибутов `in_ad`/`deal_state` — они колонки таблицы, `create(:property, in_ad: true, deal_state: 'ad')` работает без трейты (TESTING.md §3 предлагает трейту `:in_feeds` — можно добавить её).

- [ ] **Step 2: `Kpi::ShowFunnel`**

```ruby
# app/services/kpi/show_funnel.rb
# frozen_string_literal: true

module Kpi
  # BOTTLENECK — воронка показов для недельной сводки директора и /objections.
  #
  # Определения (в проекте уже четыре разных «конверсии» — здесь пятая, и она
  # намеренно другая):
  #   показ       — ShowReport.status_confirmed по conducted_at
  #   когорта     — LeadEvent.real с first_show_at в окне cohort (8 недель)
  #   конверсия   — доля лидов когорты с contract_at, считается ТОЛЬКО в ячейке
  #                 «сегмент × кто показывал»; сводной цифры по людям нет
  #                 специально — агенту по построению достаются худшие лиды
  #                 (reglament/BOTTLENECK.md, «Selection bias»)
  #   кто показывал — роль conducted_by первого подтверждённого показа лида
  #
  # KPI по объектам, а не по людям: при трёх сотрудниках персональные проценты — шум.
  class ShowFunnel
    Result = Struct.new(:week_shows, :matrix, :objects, :unreported, keyword_init: true)

    CONDUCTORS = ['руководитель', 'агент'].freeze
    UNKNOWN_SEGMENT = 'не указан'
    STUCK_SHOWS = 3

    def self.objections_summary(property:)
      reports = ShowReport.status_confirmed.for_property(property).to_a
      tags = reports.flat_map(&:objections_list).tally.sort_by { |tag, n| [-n, tag] }
      {
        shows: reports.size,
        objections: tags,
        outcomes: reports.map(&:outcome).tally,
        offered_prices: reports.filter_map(&:offered_price).map(&:to_i).sort
      }
    end

    def initialize(week:, cohort: (week.end - 8.weeks)..week.end)
      @week = week
      @cohort = cohort
    end

    def call
      Result.new(week_shows: ShowReport.confirmed_in(@week).count,
                 matrix: matrix, objects: objects, unreported: unreported_count)
    end

    def render_html
      res = call
      lines = ["🏠 <b>Показы за неделю: #{res.week_shows}</b>  · показов без отчёта: #{res.unreported}", '']
      lines << "<b>Показ → договор, когорта #{Formatters::DateFormat.fmt(@cohort.begin)}–#{Formatters::DateFormat.fmt(@cohort.end)}</b>"
      res.matrix.each do |segment, by|
        cells = CONDUCTORS.map { |c| "#{c}: #{cell(by[c])}" }.join(' · ')
        lines << "  #{segment_title(segment)} — #{cells}"
      end
      lines << '<i>Сравнивать только внутри сегмента: агенту достаются холодные лиды по построению. ' \
               'Меньше 5 показов в ячейке — не разница, а шум.</i>'
      lines << ''
      lines << '<b>Объекты</b>'
      lines << "  без показов 30 дней: #{res.objects[:no_shows_30d].size}"
      lines << "  медиана дней от публикации до первого показа: #{res.objects[:median_days_to_first_show] || '—'}"
      lines << "  ≥#{STUCK_SHOWS} показов без договора: #{res.objects[:stuck].size}#{stuck_suffix(res.objects[:stuck])}"
      lines.join("\n")
    end

    private

    def cohort_leads
      @cohort_leads ||= LeadEvent.real.where(first_show_at: @cohort).includes(:show_reports).to_a
    end

    def matrix
      rows = Hash.new { |h, k| h[k] = CONDUCTORS.to_h { |c| [c, { shows: 0, contracts: 0 }] } }
      LeadEvent::SEGMENTS.each { |s| rows[s] }
      rows[UNKNOWN_SEGMENT]
      cohort_leads.each do |lead|
        first = lead.show_reports.select(&:status_confirmed?).min_by(&:conducted_at)
        next unless first

        cell = rows[lead.segment || UNKNOWN_SEGMENT][first.conducted_by_director? ? 'руководитель' : 'агент']
        cell[:shows] += 1
        cell[:contracts] += 1 if lead.contract_at.present?
      end
      rows
    end

    def objects
      confirmed = ShowReport.status_confirmed
      shown_recently = confirmed.where(conducted_at: 30.days.ago..).where.not(property_id: nil).select(:property_id)
      no_shows = Property.in_advertising.where.not(id: shown_recently).pluck(:id)

      by_property = cohort_leads.select(&:property_id).group_by(&:property_id)
      days = by_property.filter_map do |pid, leads|
        published = Property.unscoped.find_by(id: pid)&.published_at
        next unless published

        ((leads.map(&:first_show_at).min - published) / 1.day).floor
      end

      stuck = confirmed.where.not(property_id: nil).group(:property_id).having('COUNT(*) >= ?', STUCK_SHOWS).pluck(:property_id)
      stuck -= LeadEvent.real.where.not(contract_at: nil).where(property_id: stuck).distinct.pluck(:property_id)

      { no_shows_30d: no_shows, median_days_to_first_show: median(days), stuck: stuck }
    end

    def unreported_count
      LeadEvent.real.where(first_show_at: ...24.hours.ago)
               .where.not(id: ShowReport.status_confirmed.select(:lead_event_id)).count
    end

    def median(values)
      return nil if values.empty?

      sorted = values.sort
      mid = sorted.size / 2
      sorted.size.odd? ? sorted[mid] : ((sorted[mid - 1] + sorted[mid]) / 2.0).round
    end

    def cell(c)
      return '—' if c[:shows].zero?

      "#{c[:contracts]}/#{c[:shows]} (#{(c[:contracts] * 100.0 / c[:shows]).round}%)"
    end

    def segment_title(segment)
      LeadEvent::SEGMENT_LABELS[segment] || "❔ #{segment}"
    end

    def stuck_suffix(ids)
      return '' if ids.empty?

      " — #{ids.first(5).map { |id| "##{id}" }.join(', ')}"
    end
  end
end
```

Run: `bin/rb --db bundle exec rspec spec/services/kpi/show_funnel_spec.rb` → PASS. Медиана 10 в спеке: `first_show_at = week.begin`, `published_at = week.begin - 10.days`.

- [ ] **Step 3: Блок в `WeeklySummaryJob`** — в методе, собирающем текст отчёта (там, где уже конкатенируются трендовый блок, `overdue_anomalies`, `llm_cost_report`), добавить последним:

```ruby
        show_funnel_block(range)
```

и приватный метод:

```ruby
      # BOTTLENECK — воронка показов. Падение расчёта не должно ронять всю сводку.
      def show_funnel_block(range)
        "\n#{Kpi::ShowFunnel.new(week: range).render_html}"
      rescue StandardError => e
        Rails.logger.warn("[WeeklySummaryJob#show_funnel_block] #{e.class}: #{e.message}")
        "\n🏠 Показы: расчёт недоступен (#{e.class})"
      end
```

Дополнить `spec/services/telegram/work_bot/weekly_summary_job_spec.rb` примером по образцу соседних: после создания директора и одного подтверждённого `ShowReport` за прошлую неделю — `expect(tg_client).to have_received(:send_message).with(a_string_including('Показы за неделю: 1'), anything)`.

- [ ] **Step 4: `/objections` — спека (красная)**

```ruby
# spec/services/telegram/work_bot/commands/objections_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Commands::Objections do
  let(:tg_client) { instance_double(Telegram::Client, send_message: { 'message_id' => 1 }) }
  let(:agent)    { TelegramUser.create!(tg_user_id: 111, role: 'agent', first_name: 'Ирина', status: 'active', dm_chat_id: 111) }
  let(:director) { TelegramUser.create!(tg_user_id: 333, role: 'director', first_name: 'Оксана', status: 'active') }
  let(:property) { create(:property, address: 'Рязань, ул. Есенина, 12', price: 5_500_000) }
  let!(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'tg_dm', current_stage: 'show', anchor_topic_key: 'apartments',
                      tg_chat_id: -100_1, anchor_message_id: 900, assigned_to: agent, property: property)
  end

  def run(args)
    msg = { 'chat' => { 'id' => 111, 'type' => 'private' }, 'from' => { 'id' => 111 }, 'message_id' => 5, 'text' => "/objections #{args}" }
    described_class.new(message: msg, args: args, tg_user: agent, client: tg_client).send(:handle)
  end

  it 'сводка: количество показов, теги с частотой, исходы, названные цены' do
    2.times do
      ShowReport.create!(lead_event: lead, property: property, conducted_by: director, reported_by: agent, conducted_at: 1.day.ago,
                         source: 'voice', status: 'confirmed', objections: ['маленькая кухня'], outcome: 'thinking')
    end
    ShowReport.create!(lead_event: lead, property: property, conducted_by: director, reported_by: agent, conducted_at: 1.day.ago,
                       source: 'voice', status: 'confirmed', objections: ['первый этаж'], outcome: 'bargain', offered_price: 5_200_000)
    run(lead.id.to_s)
    expect(tg_client).to have_received(:send_message).with(
      a_string_including('Есенина', '3 показ', '2× маленькая кухня', '1× первый этаж', '💬 Торг', '5 200 000'), anything
    )
  end

  it 'без показов — честно так и пишет' do
    run(lead.id.to_s)
    expect(tg_client).to have_received(:send_message).with(a_string_including('пока не было'), anything)
  end

  it 'лид без объекта — считает по лиду' do
    lead.update!(property: nil)
    run(lead.id.to_s)
    expect(tg_client).to have_received(:send_message).with(a_string_including("лид ##{lead.id}"), anything)
  end
end
```

- [ ] **Step 5: Команда**

```ruby
# app/services/telegram/work_bot/commands/objections.rb
# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # BOTTLENECK — `/objections` reply на карточку или `/objections <lead_id>`:
      # «семь показов, пять раз кухня, четыре раза первый этаж». Это и есть
      # предметный разговор о цене с собственником (Шаг 4, этап 4) — раньше он
      # собирался перечитыванием чата.
      class Objections < Base
        def handle
          lead = resolve_lead!
          return reply(lead_not_found_hint('objections')) unless lead

          property = lead.property
          summary = if property
                      Kpi::ShowFunnel.objections_summary(property: property)
                    else
                      summary_for_lead(lead)
                    end
          title = property ? escape_html(property.address) : "лид ##{lead.id}"
          return reply("🏠 #{title}: показов пока не было.") if summary[:shows].zero?

          reply(render(title, property, summary))
        end

        private

        def summary_for_lead(lead)
          reports = lead.show_reports.status_confirmed.to_a
          { shows: reports.size,
            objections: reports.flat_map(&:objections_list).tally.sort_by { |t, n| [-n, t] },
            outcomes: reports.map(&:outcome).tally,
            offered_prices: reports.filter_map(&:offered_price).map(&:to_i).sort }
        end

        def render(title, property, s)
          lines = ["🏠 <b>#{title}</b> — #{s[:shows]} #{plural(s[:shows])}"]
          lines << "Цена: #{property.price_formatted}" if property
          lines << ''
          lines << '<b>Возражения:</b>'
          lines.concat(s[:objections].first(10).map { |tag, n| "  #{n}× #{escape_html(tag)}" })
          lines << '  — возражений не записано' if s[:objections].empty?
          lines << ''
          lines << "Исходы: #{s[:outcomes].map { |o, n| "#{ShowReport::OUTCOME_LABELS[o]} #{n}" }.join(' · ')}"
          if s[:offered_prices].any?
            prices = s[:offered_prices].map { |p| ActiveSupport::NumberHelper.number_to_delimited(p, delimiter: ' ') }
            lines << "Названные цены: #{prices.join(', ')} ₽"
          end
          lines.join("\n")
        end

        def plural(n)
          return 'показов' if (11..14).cover?(n % 100)
          return 'показ' if n % 10 == 1
          return 'показа' if (2..4).cover?(n % 10)

          'показов'
        end
      end
    end
  end
end
```

Регистрация: `router.rb` `'/objections' => Commands::Objections,`; yml — `- { cmd: objections, tier: staff, group: true, desc: 'Возражения по объекту: /objections (reply на карточку)' }`; `help.rb` — `/objections` — «Сводка возражений и исходов по объекту».

- [ ] **Step 6: Прогнать, линтер, коммит, PR**

```bash
bin/rb --db bundle exec rspec spec/services/kpi/show_funnel_spec.rb spec/services/telegram/work_bot/commands/objections_spec.rb spec/services/telegram/work_bot/weekly_summary_job_spec.rb
bin/rb bundle exec rubocop app/services/kpi/show_funnel.rb app/services/telegram/work_bot
git add app/services/kpi/show_funnel.rb app/services/telegram/work_bot config/telegram_bot_commands.yml spec/
git commit -m "feat(kpi): Kpi::ShowFunnel — показ→договор внутри сегмента, метрики по объектам, /objections, блок в недельной сводке

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

Стек B: PR(ы) поверх A — `gh stack submit --open`, CI, `/code-review`, ревью снизу вверх. Объём B ~1200 строк → разбить на два PR: «модель + extractor + intake/confirmer» и «finalizer + callback + входы + KPI».

---
## Стек C — фильтр «кто едет на показ» (едет тёмным)

> Включается только `ENV['SHOW_ROUTING_ENABLED']=true` по решению руководителя после базовой линии (≥ 2 недель **и** ≥ 20 подтверждённых `ShowReport`). До этого код в проде есть, поведение бота не меняется.

### Task 10: `ShowRouting` + кнопка «кто показывает»

**Files:**
- Create: `app/services/telegram/work_bot/show_routing.rb`
- Create: `app/services/telegram/work_bot/callbacks/show_assign_callback.rb`
- Modify: `app/services/telegram/work_bot/callbacks/stage_callback.rb` и `commands/stage.rb` (после перехода в `show` — рекомендация, если флаг включён)
- Modify: `callbacks_router.rb` `PREFIX_MAP` (`'show_assign'`)
- Test: `spec/services/telegram/work_bot/show_routing_spec.rb`, `spec/services/telegram/work_bot/callbacks/show_assign_callback_spec.rb`

**Interfaces:**
- Consumes: `LeadEvent#segment`, `#show_reports`, `#assigned_to`; `TelegramUser.directors.active`; `Task.create!`; `ShowReports::Intake#conductor_for` читает `lead.metadata['show_conductor_id']` (Task 6).
- Produces: `ShowRouting.enabled? -> Boolean`; `ShowRouting.recommend(lead) -> Recommendation(conductor: :agent|:director|:unknown, reason: String)`; `ShowRouting.keyboard(lead) -> Hash` (кнопки `show_assign:<lead_id>:<tg_user_id>`); `ShowRouting.prompt_text(lead, rec) -> String`; callback `show_assign` пишет `lead.metadata['show_conductor_id']`, создаёт `Task kind: show` на выбранного.

Правила (BOTTLENECK «Ключевые идеи» п.1): холодный / ипотека не одобрена / альтернатива → агент; наличные / ипотека одобрена → руководитель; любой повторный показ или уже названная цена → руководитель; сегмент не указан → `:unknown` (сначала сегмент).

- [ ] **Step 1: Спека `ShowRouting` (красная)**

```ruby
# spec/services/telegram/work_bot/show_routing_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::ShowRouting do
  let(:agent)    { TelegramUser.create!(tg_user_id: 111, role: 'agent', first_name: 'Ирина', status: 'active') }
  let!(:director) { TelegramUser.create!(tg_user_id: 333, role: 'director', first_name: 'Оксана', status: 'active') }

  def lead!(segment:)
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'tg_dm', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1, assigned_to: agent, segment: segment)
  end

  describe '.enabled?' do
    it 'выключен без переменной и включён только на строке true' do
      stub_const('ENV', ENV.to_h.except('SHOW_ROUTING_ENABLED'))
      expect(described_class.enabled?).to be(false)
      stub_const('ENV', ENV.to_h.merge('SHOW_ROUTING_ENABLED' => 'true'))
      expect(described_class.enabled?).to be(true)
    end
  end

  describe '.recommend' do
    it 'холодный → агент' do
      rec = described_class.recommend(lead!(segment: 'cold'))
      expect(rec.conductor).to eq(:agent)
      expect(rec.reason).to include('холодный')
    end

    it 'наличные / одобренная ипотека → руководитель' do
      expect(described_class.recommend(lead!(segment: 'cash')).conductor).to eq(:director)
      expect(described_class.recommend(lead!(segment: 'mortgage_approved')).conductor).to eq(:director)
    end

    it 'ипотека не одобрена / альтернатива → агент' do
      expect(described_class.recommend(lead!(segment: 'mortgage_pending')).conductor).to eq(:agent)
      expect(described_class.recommend(lead!(segment: 'alternative')).conductor).to eq(:agent)
    end

    it 'повторный показ → руководитель независимо от сегмента' do
      lead = lead!(segment: 'cold')
      ShowReport.create!(lead_event: lead, conducted_by: agent, reported_by: agent, conducted_at: 1.day.ago,
                         source: 'voice', status: 'confirmed')
      rec = described_class.recommend(lead)
      expect(rec.conductor).to eq(:director)
      expect(rec.reason).to include('повторный')
    end

    it 'сегмент не указан → unknown' do
      expect(described_class.recommend(lead!(segment: nil)).conductor).to eq(:unknown)
    end
  end

  describe '.keyboard' do
    it 'кнопка на assignee и на каждого активного директора, ≤64 байт' do
      lead = lead!(segment: 'cold')
      buttons = described_class.keyboard(lead)[:inline_keyboard].flatten
      expect(buttons.map { |b| b[:callback_data] }).to contain_exactly("show_assign:#{lead.id}:#{agent.id}",
                                                                        "show_assign:#{lead.id}:#{director.id}")
      buttons.each { |b| expect(b[:callback_data].bytesize).to be <= 64 }
    end
  end
end
```

- [ ] **Step 2: `ShowRouting`**

```ruby
# app/services/telegram/work_bot/show_routing.rb
# frozen_string_literal: true

module Telegram
  module WorkBot
    # BOTTLENECK — фильтр «кто едет на показ». Правило из брейншторма 11.09.26:
    # холодные и неодобренные → агент; наличные, одобренная ипотека, второй
    # показ, торг на столе → руководитель. Квалификация, которую агент и так
    # выясняет по Шагу 4, впервые на что-то влияет.
    #
    # Тёмный код: без ENV SHOW_ROUTING_ENABLED=true ни одна ветка бота его не
    # вызывает. Включать — только после базовой линии (см. план).
    class ShowRouting
      Recommendation = Struct.new(:conductor, :reason, keyword_init: true)

      DIRECTOR_SEGMENTS = ['cash', 'mortgage_approved'].freeze
      AGENT_SEGMENTS    = ['cold', 'mortgage_pending', 'alternative'].freeze

      def self.enabled?
        ENV['SHOW_ROUTING_ENABLED'] == 'true'
      end

      def self.recommend(lead)
        return Recommendation.new(conductor: :unknown, reason: 'сегмент не указан') if lead.segment.blank?

        prior = lead.show_reports.status_confirmed
        if prior.exists?
          reason = prior.where.not(offered_price: nil).exists? ? 'торг уже на столе' : 'повторный показ'
          return Recommendation.new(conductor: :director, reason: reason)
        end

        label = LeadEvent::SEGMENT_LABELS[lead.segment].to_s.sub(/\A\S+\s/, '').downcase
        return Recommendation.new(conductor: :director, reason: "сегмент «#{label}»") if DIRECTOR_SEGMENTS.include?(lead.segment)

        Recommendation.new(conductor: :agent, reason: "сегмент «#{label}»")
      end

      def self.keyboard(lead)
        people = [lead.assigned_to, *TelegramUser.directors.active].compact.uniq
        row = people.map do |p|
          icon = p.role_director? ? '👑' : '👤'
          { text: "#{icon} #{p.first_name.presence || p.mention}", callback_data: "show_assign:#{lead.id}:#{p.id}" }
        end
        { inline_keyboard: [row] }
      end

      def self.prompt_text(lead, rec)
        who = { agent: 'агент', director: 'руководитель', unknown: '—' }[rec.conductor]
        head = rec.conductor == :unknown ? '❔ Сначала укажи сегмент — без него фильтр молчит.' : "🧭 Рекомендация: показывает <b>#{who}</b> (#{rec.reason})."
        "#{head}\nКто поедет на показ по лиду ##{lead.id}?"
      end
    end
  end
end
```

Run: `bin/rb --db bundle exec rspec spec/services/telegram/work_bot/show_routing_spec.rb` → PASS

- [ ] **Step 3: Спека callback'а (красная)**

```ruby
# spec/services/telegram/work_bot/callbacks/show_assign_callback_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Callbacks::ShowAssignCallback do
  let(:tg_client) do
    instance_double(Telegram::Client, send_message: { 'message_id' => 1 }, edit_message_text: { 'message_id' => 1 },
                                      answer_callback_query: { 'ok' => true })
  end
  let(:agent)    { TelegramUser.create!(tg_user_id: 111, role: 'agent', first_name: 'Ирина', status: 'active', dm_chat_id: 111) }
  let(:director) { TelegramUser.create!(tg_user_id: 333, role: 'director', first_name: 'Оксана', status: 'active', dm_chat_id: 333) }
  let(:property) { create(:property, address: 'Рязань, ул. Есенина, 12') }
  let!(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'tg_dm', current_stage: 'show', anchor_topic_key: 'apartments',
                      tg_chat_id: -100_1, anchor_message_id: 900, assigned_to: agent, segment: 'cold', property: property)
  end

  def run(target, user: agent)
    data = "show_assign:#{lead.id}:#{target.id}"
    cb = { 'id' => 'cb-1', 'data' => data, 'from' => { 'id' => user.tg_user_id },
           'message' => { 'message_id' => 55, 'text' => 'Кто поедет', 'chat' => { 'id' => -100_1, 'type' => 'supergroup' } } }
    described_class.new(callback_query: cb, tg_user: user, args: data.split(':').drop(1), client: tg_client).call
  end

  it 'назначает показывающего: metadata, Task kind show на него, DM ему, клавиатура снята' do
    run(director)
    lead.reload
    expect(lead.metadata['show_conductor_id']).to eq(director.id)
    task = Task.find_by(lead_event: lead, kind: 'show')
    expect(task.assignee).to eq(director)
    expect(task.title).to include('Есенина')
    expect(tg_client).to have_received(:send_message).with(a_string_including('Показ', 'Есенина'), hash_including(chat_id: 333))
    expect(tg_client).to have_received(:edit_message_text).with(a_string_including('Оксана'), hash_including(message_id: 55, reply_markup: { inline_keyboard: [] }))
  end

  it 'повторное нажатие на того же — «уже»' do
    run(director)
    run(director)
    expect(Task.where(lead_event: lead, kind: 'show').count).to eq(1)
    expect(tg_client).to have_received(:answer_callback_query).with('cb-1', hash_including(text: a_string_including('Уже')))
  end

  it 'чужой агент → alert' do
    other = TelegramUser.create!(tg_user_id: 222, role: 'agent', first_name: 'Б', status: 'active')
    run(director, user: other)
    expect(lead.reload.metadata['show_conductor_id']).to be_nil
  end

  it 'неизвестный сотрудник → alert' do
    data = "show_assign:#{lead.id}:999999"
    cb = { 'id' => 'cb-1', 'data' => data, 'from' => { 'id' => agent.tg_user_id }, 'message' => { 'message_id' => 55, 'chat' => { 'id' => -100_1 } } }
    described_class.new(callback_query: cb, tg_user: agent, args: data.split(':').drop(1), client: tg_client).call
    expect(tg_client).to have_received(:answer_callback_query).with('cb-1', hash_including(show_alert: true))
  end
end
```

- [ ] **Step 4: Callback**

```ruby
# app/services/telegram/work_bot/callbacks/show_assign_callback.rb
# frozen_string_literal: true

module Telegram
  module WorkBot
    module Callbacks
      # BOTTLENECK — «кто поедет на показ». callback_data: "show_assign:<lead_id>:<tg_user_id>".
      # Пишет metadata['show_conductor_id'] (его подхватит ShowReports::Intake как
      # показывающего по умолчанию) и ставит Task kind: show на выбранного.
      # Расклеиваем показ и торг: показ — задача исполнителя, торг — остаётся у руководителя.
      class ShowAssignCallback < Base
        def handle
          lead = lead_event
          return ack('🚫 Назначает assignee лида или руководитель', alert: true) unless authorized?(lead)

          conductor = TelegramUser.active.find_by(id: @args[1].to_i)
          return ack('⚠️ Сотрудник не найден или неактивен', alert: true) if conductor.nil?
          return ack("ℹ️ Уже назначен: #{conductor.display_name}") if lead.metadata['show_conductor_id'] == conductor.id

          lead.with_lock do
            lead.reload
            lead.update!(metadata: lead.metadata.merge('show_conductor_id' => conductor.id,
                                                       'show_conductor_set_at' => Time.current.iso8601,
                                                       'show_conductor_set_by' => actor_mention))
          end
          task = create_show_task(lead, conductor)
          dm_conductor(lead, conductor, task)
          strike_prompt("\n\n✅ Показывает <b>#{escape(conductor.display_name)}</b> (задача ##{task.id})")
          ack("✅ #{conductor.display_name}")
        end

        private

        def authorized?(lead)
          return false if tg_user.nil?

          lead.assigned_to_id == tg_user.id || tg_user.manager_or_director?
        end

        def create_show_task(lead, conductor)
          ::Task.create!(lead_event: lead, assignee: conductor, created_by: tg_user, kind: 'show', priority: 'normal',
                         status: 'open', title: "Показ: #{address(lead)}"[0, 255], assigned_at: Time.current)
        end

        def dm_conductor(lead, conductor, task)
          chat_id = conductor.dm_chat_id || conductor.tg_user_id
          return if chat_id.blank?

          text = "🏠 <b>Показ за тобой</b> — #{escape(address(lead))}\n" \
                 "Покупатель: #{escape(lead.metadata['name'].presence || "лид ##{lead.id}")} · #{lead.segment_label}\n" \
                 "После показа — голосовое боту или <code>/show #{lead.id} …</code>. Задача ##{task.id}." \
                 "#{lead.anchor_url ? "\n#{lead.anchor_url}" : ''}"
          client.send_message(text, chat_id: chat_id, parse_mode: 'HTML')
        rescue Telegram::Client::Error => e
          Rails.logger.warn("[ShowAssignCallback] DM failed: #{e.message}")
        end

        def strike_prompt(suffix)
          msg = callback_query['message']
          return if msg.blank?

          client.edit_message_text("#{msg['text']}#{suffix}", chat_id: msg.dig('chat', 'id'), message_id: msg['message_id'],
                                                               parse_mode: 'HTML', reply_markup: { inline_keyboard: [] })
        rescue Telegram::Client::Error => e
          Rails.logger.warn("[ShowAssignCallback] edit failed: #{e.message}")
        end

        def address(lead)
          lead.property&.address.presence || "лид ##{lead.id}"
        end

        def escape(text)
          text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
        end
      end
    end
  end
end
```

Зарегистрировать `'show_assign' => 'Telegram::WorkBot::Callbacks::ShowAssignCallback'` в `PREFIX_MAP`.

- [ ] **Step 5: Хук после перехода в `show`** — в `StageCallback#handle` и `Commands::Stage#handle`, сразу после нуджа сегмента:

```ruby
          propose_conductor(lead) if stage == 'show' && ShowRouting.enabled? && lead.segment.present?
```

и приватный метод в обоих (в callback — через `reply_in_topic`, в команде — через `reply`):

```ruby
        # BOTTLENECK — фильтр «кто едет». Только при включённом флаге и известном сегменте.
        def propose_conductor(lead)
          rec = ShowRouting.recommend(lead)
          reply_in_topic(ShowRouting.prompt_text(lead, rec), reply_markup: ShowRouting.keyboard(lead))
        rescue Telegram::Client::Error => e
          Rails.logger.warn("[StageCallback] routing prompt failed: #{e.message}")
        end
```

Добавить в `stage_callback_spec.rb` пример: при `stub_const('ENV', ENV.to_h.merge('SHOW_ROUTING_ENABLED' => 'true'))` и `segment: 'cold'` после `stage:<id>:show` приходит сообщение с «Рекомендация» и кнопками `show_assign:`; при выключенном флаге — не приходит.

- [ ] **Step 6: Прогнать, линтер, коммит**

```bash
bin/rb --db bundle exec rspec spec/services/telegram/work_bot/show_routing_spec.rb spec/services/telegram/work_bot/callbacks
bin/rb bundle exec rubocop app/services/telegram/work_bot
git add app/services/telegram/work_bot spec/services/telegram/work_bot
git commit -m "feat(shows): ShowRouting + show_assign — фильтр «кто едет на показ», тёмный за SHOW_ROUTING_ENABLED

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 11: `/bargain` — торг на объекте: руководитель получает контекст до звонка

**Files:**
- Create: `app/services/telegram/work_bot/commands/bargain.rb`
- Modify: `router.rb` `COMMANDS`, `config/telegram_bot_commands.yml`, `commands/help.rb` `ENTRIES`
- Test: `spec/services/telegram/work_bot/commands/bargain_spec.rb`

**Interfaces:**
- Consumes: `Telegram::CriticalRecipients.resolve -> Result(each, tier, fallback?)`; `Kpi::ShowFunnel.objections_summary(property:)` (Task 9); `LeadEvent#append_history`, `#anchor_url`, `Property#price_formatted`; `ShowReports::Extractor#parse_price` — логику парсинга цены **продублировать не надо**: вынести из Extractor в `Formatters::PriceParse.call(raw) -> BigDecimal|nil` (`app/services/formatters/price_parse.rb`) и использовать из обоих мест.
- Produces: `/bargain <цена>` reply на карточку или `/bargain <lead_id> <цена>` в DM; DM всем получателям каскада `CriticalRecipients` немедленно (реактивное сообщение — quiet hours не применяются, показ и так днём); `lead.metadata['bargain_requests']` (история, cap 5 по `HISTORY_DEFAULT_CAPS` — добавить ключ `'bargain_requests' => 10`).

Зачем: BOTTLENECK «Разрыв момента — главный операционный риск»: покупатель стоит в квартире и называет цифру; агент набирает руководителя и передаёт трубку. Команда за секунду до звонка даёт руководителю карточку: цена объекта, названная цена, сегмент, сколько было показов, что не нравилось. Торг остаётся у руководителя — но подготовленного.

- [ ] **Step 1: Вынести парсер цены**

```ruby
# app/services/formatters/price_parse.rb
# frozen_string_literal: true

module Formatters
  # «5,2 млн» / «5 200 000» / «5.2млн» / 5200000 → BigDecimal или nil.
  # Используется ShowReports::Extractor и /bargain — одна интерпретация цифры голосом и текстом.
  module PriceParse
    module_function

    def call(raw)
      return nil if raw.blank?
      return raw.to_d if raw.is_a?(Numeric)

      s = raw.to_s.downcase.gsub(/\s/, '').tr(',', '.')
      millions = s.include?('млн')
      num = s[/\d+(?:\.\d+)?/]
      return nil if num.nil?

      value = num.to_d
      value *= 1_000_000 if millions
      value.positive? ? value : nil
    end
  end
end
```

В `ShowReports::Extractor` заменить тело `parse_price(raw)` на `Formatters::PriceParse.call(raw)`; спека extractor'а остаётся зелёной.

- [ ] **Step 2: Спека команды (красная)**

```ruby
# spec/services/telegram/work_bot/commands/bargain_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Commands::Bargain do
  let(:tg_client) { instance_double(Telegram::Client, send_message: { 'message_id' => 1 }) }
  let(:agent)     { TelegramUser.create!(tg_user_id: 111, role: 'agent', first_name: 'Ирина', status: 'active', dm_chat_id: 111) }
  let!(:director) { TelegramUser.create!(tg_user_id: 333, role: 'director', first_name: 'Оксана', status: 'active', dm_chat_id: 333) }
  let(:property)  { create(:property, address: 'Рязань, ул. Есенина, 12', price: 5_500_000) }
  let!(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'tg_dm', current_stage: 'show', anchor_topic_key: 'apartments',
                      tg_chat_id: -100_1, anchor_thread_id: 17, anchor_message_id: 900, assigned_to: agent,
                      segment: 'cash', property: property, metadata: { 'name' => 'Анна' })
  end

  before do
    ShowReport.create!(lead_event: lead, property: property, conducted_by: agent, reported_by: agent, conducted_at: 1.day.ago,
                       source: 'voice', status: 'confirmed', objections: ['маленькая кухня'])
  end

  def run(args)
    msg = { 'chat' => { 'id' => 111, 'type' => 'private' }, 'from' => { 'id' => 111 }, 'message_id' => 5, 'text' => "/bargain #{args}" }
    described_class.new(message: msg, args: args, tg_user: agent, client: tg_client).send(:handle)
  end

  it 'руководитель получает карточку: объект, цена, названная цена, сегмент, показы, возражения, ссылка на якорь' do
    run("#{lead.id} 5,2 млн")
    expect(tg_client).to have_received(:send_message).with(
      a_string_including('Торг на объекте', 'Есенина', '5 500 000', '5 200 000', 'Наличные', '1 показ', 'маленькая кухня', 'Ирина', 't.me/c/'),
      hash_including(chat_id: 333)
    )
  end

  it 'агенту — подтверждение «звони»; в metadata — история' do
    run("#{lead.id} 5200000")
    expect(tg_client).to have_received(:send_message).with(a_string_including('звони'), hash_including(chat_id: 111))
    entry = lead.reload.metadata['bargain_requests'].last
    expect(entry['price']).to eq(5_200_000)
    expect(entry['by']).to eq(agent.mention)
  end

  it 'цена не распознана → формат' do
    run("#{lead.id} дорого")
    expect(tg_client).to have_received(:send_message).with(a_string_including('Формат'), anything)
    expect(tg_client).not_to have_received(:send_message).with(anything, hash_including(chat_id: 333))
  end

  it 'директор с заблокированным ботом не ломает рассылку остальным' do
    admin = TelegramUser.create!(tg_user_id: 444, role: 'director', first_name: 'Зам', status: 'active', dm_chat_id: 444)
    allow(tg_client).to receive(:send_message).with(anything, hash_including(chat_id: 333)).and_raise(Telegram::Client::Error, 'bot was blocked')
    run("#{lead.id} 5200000")
    expect(tg_client).to have_received(:send_message).with(anything, hash_including(chat_id: admin.dm_chat_id))
  end
end
```

- [ ] **Step 3: Команда**

```ruby
# app/services/telegram/work_bot/commands/bargain.rb
# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # BOTTLENECK — «разрыв момента». Покупатель стоит в квартире и называет цифру;
      # агент жмёт /bargain и набирает руководителя. За секунду до звонка у
      # руководителя в DM уже карточка: цена объекта, названная цена, сегмент,
      # сколько было показов и что не нравилось. Торг остаётся у руководителя —
      # но подготовленного. Реактивное сообщение: quiet hours не применяются.
      class Bargain < Base
        def handle
          lead = resolve_lead!
          return reply(lead_not_found_hint('bargain 5,2 млн')) unless lead

          price = Formatters::PriceParse.call(@args.to_s)
          return reply('Формат: <code>/bargain 5,2 млн</code> (reply на карточку) или <code>/bargain &lt;lead_id&gt; 5200000</code> в личке.') if price.nil?

          record!(lead, price)
          delivered = notify_directors(lead, price)
          return reply('⚠️ Ни один руководитель не получил DM — звони напрямую.') if delivered.zero?

          reply("📞 Руководитель предупреждён (#{delivered}) — звони и передавай трубку.")
        end

        private

        def record!(lead, price)
          history = lead.append_history(key: 'bargain_requests',
                                        entry: { 'at' => Time.current.iso8601, 'price' => price.to_i, 'by' => tg_user.mention })
          lead.update!(metadata: lead.metadata.merge('bargain_requests' => history))
        end

        def notify_directors(lead, price)
          text = card(lead, price)
          delivered = 0
          Telegram::CriticalRecipients.resolve.each do |recipient|
            chat_id = recipient.dm_chat_id || recipient.tg_user_id
            next if chat_id.blank?

            client.send_message(text, chat_id: chat_id, parse_mode: 'HTML')
            delivered += 1
          rescue Telegram::Client::Error => e
            Rails.logger.warn("[Commands::Bargain] DM to #{recipient.mention} failed: #{e.message}")
          end
          delivered
        end

        def card(lead, price)
          property = lead.property
          summary = property ? Kpi::ShowFunnel.objections_summary(property: property) : { shows: 0, objections: [] }
          objections = summary[:objections].first(4).map { |t, n| "#{n}× #{escape_html(t)}" }.join(', ')
          lines = ["🔥 <b>Торг на объекте</b> — #{escape_html(tg_user.display_name)} сейчас с покупателем"]
          lines << "Объект: #{escape_html(property&.address.presence || "лид ##{lead.id}")}"
          lines << "Цена: <b>#{property&.price_formatted || '—'}</b> · предлагают: <b>#{delimited(price)} ₽</b>"
          lines << "Покупатель: #{escape_html(lead.metadata['name'].presence || '—')} · #{lead.segment_label}"
          lines << "Показов: #{summary[:shows]} #{plural(summary[:shows])}#{objections.present? ? " · #{objections}" : ''}"
          lines << lead.anchor_url if lead.anchor_url
          lines.join("\n")
        end

        def delimited(price)
          ActiveSupport::NumberHelper.number_to_delimited(price.to_i, delimiter: ' ')
        end

        def plural(n)
          return 'показов' if (11..14).cover?(n % 100)
          return 'показ' if n % 10 == 1
          return 'показа' if (2..4).cover?(n % 10)

          'показов'
        end
      end
    end
  end
end
```

В `LeadEvent::HISTORY_DEFAULT_CAPS` добавить `'bargain_requests' => 10, 'segment_history' => 10`.

Регистрация: `router.rb` `'/bargain' => Commands::Bargain,`; yml — `- { cmd: bargain, tier: staff, group: true, desc: 'Торг на объекте: /bargain 5,2 млн — руководитель получит карточку до звонка' }`; `help.rb` — `/bargain` — «Покупатель назвал цену — предупредить руководителя перед звонком».

- [ ] **Step 4: Прогнать, линтер, коммит, PR стека C**

```bash
bin/rb --db bundle exec rspec spec/services/telegram/work_bot/commands/bargain_spec.rb spec/services/telegram/work_bot/show_reports/extractor_spec.rb
bin/rb bundle exec rubocop app/services/formatters/price_parse.rb app/services/telegram/work_bot/commands/bargain.rb app/services/telegram/work_bot/show_reports/extractor.rb
git add app/services/formatters/price_parse.rb app/services/telegram/work_bot app/models/lead_event.rb config/telegram_bot_commands.yml spec/
git commit -m "feat(work_bot): /bargain — карточка торга руководителю до звонка с объекта; Formatters::PriceParse

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 12: Документация, меню бота, инструкция запуска базовой линии

**Files:**
- Modify: `.claude/docs/reglament/BOTTLENECK.md` (секция «Следующий шаг» → ссылка на этот план и статус)
- Modify: `.claude/docs/reglament/step-04-inbound-shows-review.md` (I2–I5 — пометить «решается планом 2026-09-11»)
- Modify: `.claude/memory/activeContext.md` (ветка `claude/show-delegation`, фаза «базовая линия показов»)
- Modify: `app/services/telegram/work_bot/cheatsheet_renderer.rb` (секция «Показы»)
- Modify: `.env.example` (`SHOW_ROUTING_ENABLED=false`, проверить `LLM_CHAIN_STAFF_ANALYSIS` задокументирован)
- Create: `.claude/docs/reglament/SHOWS-BASELINE.md`

**Interfaces:** нет кода; документ для руководителя и для сессии, которая будет снимать итоги через две недели.

- [ ] **Step 1: `SHOWS-BASELINE.md`**

```markdown
# Базовая линия по показам — как запустить и как читать

Срок: 2 недели с даты деплоя стеков A+B. Фильтр (`SHOW_ROUTING_ENABLED`) выключен — кто ездит на показы, не меняется.

## Что делают люди (три действия, всё в Telegram)

1. **Сегмент покупателя** — кнопка под карточкой лида в #ДИСПЕТЧЕРСКОЙ (💵 Нал / 🏦 Ипотека ✓ / ⏳ Ипотека ? / 🔄 Альт / ❄️ Холод) или `/segment`. Бот напомнит сам при переходе в «показ».
2. **Стадия** — кнопки 📅 Показ / ✍️ Договор под карточкой (или `/stage`).
3. **Отчёт после показа** — голосовое боту в личку (кто угодно из сотрудников) или `/show <id> текст`. Бот покажет превью → ✅ Сохранить. Дальше сам: стадия, задача «собственнику до 11:00», черновик сообщения собственнику с кнопкой отправки.

## Что делает бот

- Понедельник 10:00, DM директору — блок «Показы»: показ→договор по ячейкам «сегмент × кто показывал», объекты без показов 30 дней, медиана дней до первого показа, объекты с ≥3 показами без договора, показы без отчёта.
- `/objections` reply на карточку — «7 показов · 5× кухня · 4× первый этаж», цены, которые называли.
- Просрочка «собственнику до 11:00» — пинг от `Sla::TasksWatchdogJob`.

## Как читать цифры (три ловушки из BOTTLENECK.md)

- Сравнивать **только внутри сегмента**: строка «❄️ Холодный — руководитель: 1/6 · агент: —» через две недели станет «руководитель (до) ↔ агент (после)».
- Ячейка меньше 5 показов — шум, не разница.
- Главная метрика — конверсия показ→договор, она защищена сама собой; «показ проведён» без отчёта виден в «показов без отчёта».

## Когда включать фильтр

Оба условия: прошло ≥ 14 дней **и** `ShowReport.status_confirmed.count >= 20`. Проверка: `bin/rails runner 'p ShowReport.status_confirmed.count, ShowReport.status_confirmed.minimum(:conducted_at)'`.
Включение: `SHOW_ROUTING_ENABLED=true` в `.env`, рестарт `victory-web-1` и sidekiq (`/usr/bin/docker compose ... restart`). После включения при переходе в «показ» бот предлагает «кто поедет» с кнопками; `/bargain` — для торга с объекта.

## Самое рискованное допущение

Если через 6–8 недель после включения разница конверсий внутри сегментов в пределах шума — решение принимается по стоимости времени руководителя, не по цифрам. Это нормальный исход; не путать отсутствие сигнала с отсутствием эффекта.
```

- [ ] **Step 2: Шпаргалка бота** — в `cheatsheet_renderer.rb` добавить секцию «🏠 Показы» для tier staff: `/segment`, кнопки стадий, голосовое после показа, `/show`, `/objections`, `/bargain` (последний — с пометкой «после включения фильтра»).

- [ ] **Step 3: BOTTLENECK.md и review** — в BOTTLENECK.md «Следующий шаг» добавить строку: «Реализация: `docs/superpowers/plans/2026-09-11-show-delegation-telegram.md`, инструкция запуска — `SHOWS-BASELINE.md`». В `step-04-inbound-shows-review.md` к I2/I3/I4/I5 — «→ план 11.09.26: ShowReport / Task до 11:00 / StageCallback».

- [ ] **Step 4: Меню бота и деплой-чеклист**

```bash
bin/rb --web 'bin/rails telegram:sync_commands'   # после деплоя — иначе новые команды не появятся в «/»-меню
```

В `activeContext.md` — ветка, что в проде, дата старта базовой линии (dd.MM.yy), дата, когда смотреть итоги (+14 дней).

- [ ] **Step 5: Коммит**

```bash
git add .claude/docs/reglament .claude/memory/activeContext.md app/services/telegram/work_bot/cheatsheet_renderer.rb .env.example
git commit -m "docs(shows): SHOWS-BASELINE — как запустить и читать базовую линию; шпаргалка бота, статус BOTTLENECK

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Что намеренно не делается

- **Не трогаем распределение показов** до конца базовой линии (BOTTLENECK «Следующий шаг» п.3–4).
- **Не чиним `ViewingSchedule`** — модель расходится со схемой; `ShowReport` строится отдельно. Поломка зафиксирована в отчёте исследования, отдельный issue.
- **Не добавляем SLA-пинг «показ без отчёта»** — цифра в недельной сводке достаточна для двух недель; при необходимости — `Sla::PingService` новый `kind`, по образцу DESIGN.md §4.4.
- **Не исправляем расхождение `manager_only` в `Callbacks::Base`** (смотрит `is_manager?`) — новые callback'и обходят его собственным `authorized?`; фикс старых семи callback'ов — отдельный PR.
- **Не меняем 30 → 15 минут первого ответа** (I1) — решение агентства, фаза 0 DESIGN.md.
- **Не шлём собственнику ничего без кнопки** — черновик всегда проходит через агента. Тихие часы это правило не ослабляют: в 22:30 кнопка не отправляет, а говорит, когда нажать (Task 7, Step 5).
- **Не включаем строгую проверку секрета вебхука.** Разбор 10.09.26: пустой `X-Telegram-Bot-Api-Secret-Token` принимается безусловно — обход, поставленный после суточного простоя в мае, когда Cloudflare Worker срезал заголовок. Сейчас Worker его прокидывает, и проверку действительно можно закрывать. Но цена ошибки асимметрична: закрыли неверно — бот глухой (те самые сутки), оставили открытым — теоретическая подделка апдейтов тем, кто угадает URL вебхука. Это отдельный PR со своим планом откатa, а не попутная правка в стеке, который и так меняет диспетчер. Зафиксировать как follow-up после стека C.
- **Не принимаем реакцию как подтверждение отчёта о показе.** Реакция здесь — полноценный элемент интерфейса: 👍 на карточке ставит `first_contact_at` (ветка 02 диспетчера), и соблазн сделать 👍 = «показ подтверждён» велик — агенту на улице это дешевле кнопки. Не делаем: превью отчёта — это **проверка извлечённых данных** (лид, исход, возражения, названная цена), а реакция не выражает согласия с конкретным текстом, который LLM только что сочинила. Путь 👍 → `first_contact_at` остаётся как есть и плану не мешает.
- **Не правим `/help` для клиента.** Находка разбора «клиент видит каталог команд сотрудников» при проверке по коду **не подтвердилась**: `Commands::Help#handle` выводит незарегистрированному только секцию `:public` и подсказку про привязку. Подтвердилась лишь подсказка `Доступно: /whoami` из `Router` — она закрыта в Task 0B.
- **Не чиним расхождение прав в старых семи callback'ах** (`Callbacks::Base#manager_only` смотрит `is_manager?`, команды — `manager_or_director?`; директор с `is_manager: false` проходит командой и получает отказ на кнопке). Новые callback'и плана обходят базовый гейт своим `authorized?` на `manager_or_director?`, так что расхождение не тиражируется. Фикс старых — отдельный PR.

## Известные ловушки для исполнителя (из исследования кода и сверки с разбором 10.09.26)

1. `:staff_analysis` — не ключ `DEFAULT_CHAINS`; цепочка живёт в `ENV['LLM_CHAIN_STAFF_ANALYSIS']`, без неё `OmniClient` молча уходит в `:chat`. Проверить `.env.example`.
2. `TaskBatchConfirmCallback#edit_preview` ссылается на несуществующий `@cb` — не копировать; использовать `callback_query` (как сделано в Task 7).
3. `Telegram::Client#edit_message_reply_markup` и `#pin_chat_message` падают на kwargs-хвосте — не использовать.
4. Список стадий живёт в пяти местах (`LeadEvent::STAGES`, `LeadStageTransition`, `LeadAnnouncer`, `DealMirror`, `Embedding::LeadEventTextTemplate`) — план стадий не добавляет, поэтому синхронизировать нечего. Сегмент — в одном (`LeadEvent`).
5. `Sla::WatchdogJob`/`TasksWatchdogJob` не в `sidekiq_cron.yml` — расписание в `config/schedule.rb` (whenever). Перед тем как обещать пинг «до 11:00», убедиться, что `TasksWatchdogJob` реально гоняется в проде; если нет — добавить строку в `sidekiq_cron.yml` (`*/5 * * * *`).
6. Фабрик `telegram_user` / `lead_event` / `task` нет — в спеках `create!` руками, как в соседних спеках. `FactoryBot.lint` ошибки не роняет.
7. `Commands::Base#call` глотает исключения в «⚠️ Ошибка» — в спеках вызывать `.send(:handle)`.
8. `WeeklySummaryJob` и `Kpi::WeeklyReport` оба в понедельник 10:00 и с разными формулами конверсии — блок показов добавляется только в первый (директорский), формула описана в `Kpi::ShowFunnel`.
9. **Клавиатура карточки лида рисуется в трёх местах**, не в одном: `#send_card` (публикация и переезд через `#repost_to`), `.refresh!` (его вызывает `PropertyValuationJob` после расчёта оценки) и callback'и перерисовки. Пропустить `.refresh!` — значит получить плавающий баг: успешный расчёт оценки стирает с карточки ряды сегмента и стадий. См. Task 2, Step 5.
10. **`AnchorMigrator#call` делает `repost_to(target)` до `update!(anchor_topic_key: target)`** — на момент отрисовки лид в базе ещё «в диспетчерской». Клавиатуру строить от переданного `topic_key`, иначе кнопки маршрутизации уедут в спец-топик вместе с карточкой.
11. **Голосовую ветку диспетчера менять не надо:** `VoiceIntakeProcessor.applies?` проверяет только `msg['voice']` и `chat.type == 'private'`, роль в ней не участвует — расширение гейта живёт внутри `#call`. Там же уже есть `return refuse_unregistered(from_id) if tg_user.nil?` **перед** проверкой роли, поэтому `tg_user.status` на nil не упадёт. Но комментарий над веткой в `inbound_processor.rb` («voice от директора АН») станет ложью — поправить (Task 8, Step 7).
12. **Все `Result` в проекте — `Struct`.** `Lead::Intake::Result`, `VoiceTranscriber::Result`, `Telegram::PushToClient::Result`. Проверка `is_a?(Hash)` против такого Struct'а уже один раз молча отключила подтверждение заявки клиенту, и спека это пропустила, потому что стабила литеральный хэш. Стабить настоящим Struct'ом.
13. **`BotCommandLog.result` пишется строкой символа исхода** (`handled`, `denied_manager`, `error`). Не писать туда возврат `reply` — это хэш ответа Telegram API целиком.
