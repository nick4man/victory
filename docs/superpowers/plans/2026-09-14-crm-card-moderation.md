# Карточки CRM через модерацию — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ни заявка, ни объект не попадают в CRM Topnlab без пути «контакт с клиентом → дозаполнение карточки → машинная проверка → модерация директором → выгрузка», одинакового для лидов с сайта и карточек из Telegram, с правами сотрудника, унаследованными из его должности в CRM.

**Architecture:** Новая модель `CrmCard` (+ журнал `CrmCardTransition`) с машиной статусов, все переходы которой живут в одном сервисе `CrmCards::Workflow`. Права — `CrmCards::Permissions`: должность и статус учётки из CRM (`users.crm_role_id`/`crm_status`, ночной `TopnlabStaffSyncJob`) через таблицу `config/crm_permissions.yml`. Поля карточки и их нормализация — `CrmCards::Schema` + `FieldValue`, проверка — `CrmCards::Checker`. Интерфейс — существующие мастера `Wizard::Engine` в личке и кнопка под карточкой лида. Заявка выгружается джобом через `Topnlab::Client#import_client` с атомарным захватом статуса; объект — вручную по «паспорту» до появления шлюза.

**Tech Stack:** Rails 8.1.3.1 / Ruby 3.4.10 / PostgreSQL 15 (`db/structure.sql`), ActiveJob на Sidekiq, Telegram Bot API через `Telegram::Client`, `Topnlab::Client` (публичный API), RSpec + WebMock + FactoryBot.

**Spec:** `docs/superpowers/specs/2026-09-14-crm-card-moderation-design.md`. Контекст — `.claude/docs/topnlab/plugin-integration-assessment.md` (§2.2 «лиды с сайта в CRM не уходят», §5.2, §9 вопрос 4), `.claude/docs/reglament/DESIGN.md` («сотрудники живут в Telegram»).

## Global Constraints

- **Worktree:** код пишется в новом worktree `~/victory-crm-cards` на ветке `claude/crm-card-moderation` (`git -C ~/victory worktree add ~/victory-crm-cards -b claude/crm-card-moderation main`). `~/victory` — live-prod bind-mount, туда не писать; чужие worktree — только чтение.
- **Ruby только через `bin/rb`:** `bin/rb --db bundle exec rspec <path>`, `bin/rb bundle exec rubocop -a <paths>`. Перед первым прогоном `bin/rb --seed-bundle` и `bin/rb --db bin/rails db:prepare`. Не докладывать «зелёное», не прогнав там, где Ruby есть.
- **Стек PR** по правилам `gh-stack` (CLAUDE.md): A «данные и права» (Tasks 1–4) → B «конвейер» (Tasks 5–8) → C «Telegram: заявки» (Tasks 9–12) → D «объекты» (Tasks 13–15). Task 16 — запуск, без кода. `/code-review <PR#>` на каждый PR после зелёного CI.
- Каждый `.rb` — `# frozen_string_literal: true`, одинарные кавычки, комментарии по-русски и про «почему», а не «что».
- Enum'ы — только `prefix: true`, русский перевод значения в комментарии рядом (правило 2 CLAUDE.md).
- Soft-delete на `CrmCard`: `deleted_at` + `scope :not_deleted` + `default_scope { not_deleted }`. `CrmCardTransition` — журнал только на добавление, soft-delete не нужен (обоснование в модели).
- Даты в сообщениях — `Formatters::DateFormat.fmt` / `.fmt_dt` (`dd.MM.yy`, `dd.MM.yy HH:MM`).
- `db/structure.sql` руками не править — регенерируется `bin/rb --db bin/rails db:migrate` и коммитится вместе с миграцией. Миграции `ActiveRecord::Migration[8.1]` с русским комментарием-«почему» над классом.
- **Права — только из CRM.** Нигде не проверять `tg_user.role`, `is_manager?`, `manager_or_director?`, `can_voice_distribute?` для действий с карточками — только `CrmCards::Permissions.for(tg_user).can?(...)`. Роль в боте ставится вручную и расходится с CRM (spec §8).
- **Статус карточки меняет только `CrmCards::Workflow`.** Мастера, кнопки и команды вызывают его методы; `card.update!(status: …)` вне Workflow запрещён (исключение — подготовка данных в спеках).
- **Единственный вызов `Topnlab::Client#import_client` — `CrmCards::LeadExporter`.** Закреплено спекой (Task 5).
- **Карточка с телефоном клиента — только в личке.** В группу уходят только кнопка и статус, без полей.
- Telegram: `parse_mode: 'HTML'` → пользовательский текст экранировать. Ошибки `accept` мастера Engine выводит **без экранирования** — поэтому тексты ошибок `FieldValue` не содержат ввода пользователя. `callback_data` — ASCII, ≤ 64 байт. Каждый путь callback'а заканчивается `ack(...)`.
- Мастер без единого вопроса не завершится (`Engine#claim_state!` ищет сохранённое состояние, которого ещё нет), поэтому у мастеров заполнения последний шаг — `:confirm`.
- Новая команда регистрируется в **трёх** местах: `Router::COMMANDS`, `config/telegram_bot_commands.yml`, `Commands::Help::ENTRIES`; инвариант сторожит `spec/services/telegram/work_bot/command_registries_spec.rb`.
- **`Result` — `Struct`, а не `Hash`.** Никогда `result.is_a?(Hash)`; в спеках стабить настоящий `Result`.
- **Джоб выгрузки не пробрасывает исключения.** `ApplicationJob` объявляет `retry_on StandardError, attempts: 3`, а повторный `import_client` после таймаута заводит вторую заявку.
- Коммит после каждой задачи; трейлер `Co-Authored-By` — как задаёт сессия-исполнитель.

## File Structure

**Стек A — данные и права**

| Файл | Ответственность |
|---|---|
| `db/migrate/20260914120000_create_crm_cards.rb` | таблицы `crm_cards`, `crm_card_transitions`; одна карточка заявки на лид |
| `app/models/crm_card.rb` | enum'ы вида, статуса и режима выгрузки, `STATUS_LABELS`, soft-delete, `check_passed?`, `export_stale?`, `last_rework_comment` |
| `app/models/crm_card_transition.rb` | запись журнала решений |
| `config/crm_permissions.yml` | должность в CRM → возможности |
| `app/services/crm_cards/permissions.rb` | права сотрудника из его учётки в CRM, отказ с причиной |
| `app/services/crm_cards/permissions_report.rb`, `lib/tasks/crm_cards.rake` | сводка «кто что может» для руководителя |
| `app/services/crm_cards/schema.rb` | поля карточки заявки (объект — Task 13) |
| `app/services/crm_cards/field_value.rb` | нормализация одного значения: `[значение, ошибка]` |
| `app/services/crm_cards/checker.rb` | машинная проверка карточки |
| `spec/support/crm_card_helpers.rb` | `stub_crm_positions`, `crm_staff` — сотрудник с должностью в CRM |

**Стек B — конвейер**

| Файл | Ответственность |
|---|---|
| `app/services/crm_cards/lead_exporter.rb` | заявка → `import_client` + `transfer_client` |
| `app/services/crm_cards/card_view.rb` | текст карточки и кнопки под зрителя |
| `app/services/crm_cards/notifier.rb` | личные сообщения участникам + перерисовка карточки лида |
| `app/services/crm_cards/workflow.rb` | все переходы статусов, права, журнал, выгрузка |
| `app/jobs/crm_cards/export_job.rb` | тонкий джоб: `Workflow#export!` без автоповтора |

**Стек C — Telegram: заявки**

| Файл | Ответственность |
|---|---|
| `spec/support/wizard_dm_harness.rb` | общий контекст «нажать кнопку / написать текст» для спек мастеров |
| `app/services/telegram/work_bot/wizard/crm_card_support.rb` | шаг на поле схемы, проверка ввода, поиск карточки |
| `app/services/telegram/work_bot/wizard/crm_lead_card_flow.rb` | мастер заполнения заявки по лиду |
| `app/services/telegram/work_bot/wizard/crm_card_edit_flow.rb` | мастер «изменить поле» |
| `app/services/telegram/work_bot/wizard/crm_card_rework_flow.rb` | модератор возвращает на доработку |
| `app/services/telegram/work_bot/wizard/crm_card_approve_flow.rb` | модератор одобряет |
| `app/services/telegram/work_bot/wizard/engine.rb` | регистрация мастеров в `FLOWS` / `SEED_STEP` |
| `app/services/telegram/work_bot/callbacks/crm_card_callback.rb` | `crm_card:<id>:view|submit|retry` |
| `app/services/telegram/work_bot/callbacks_router.rb` | префикс `crm_card` |
| `app/services/telegram/work_bot/lead_announcer.rb` | ряд «📋 Карточка CRM» / статус под карточкой лида |
| `app/services/telegram/work_bot/lead_assignment.rb` | кнопка карточки в личку назначенному |
| `app/services/telegram/work_bot/commands/cards.rb` + `router.rb`, `commands/help.rb`, `config/telegram_bot_commands.yml` | `/cards` |

**Стек D — объекты**

| Файл | Ответственность |
|---|---|
| `app/services/crm_cards/schema.rb`, `checker.rb` | поля объекта и правила площадей, этажей, договора |
| `app/services/telegram/work_bot/wizard/crm_object_card_flow.rb` | мастер нового объекта |
| `app/services/telegram/work_bot/wizard/menu.rb` | «🏠 Новый объект в CRM» по праву `create_object` |
| `app/services/telegram/work_bot/wizard/crm_card_manual_export_flow.rb` | «Внесено в CRM» + номер карточки |

Спеки зеркалят пути под `spec/`.

---

## Стек A — данные и права

### Task 1: Модель карточки и журнал решений

**Files:**
- Create: `db/migrate/20260914120000_create_crm_cards.rb`
- Create: `app/models/crm_card.rb`
- Create: `app/models/crm_card_transition.rb`
- Modify: `db/structure.sql` (регенерация, не руками)
- Test: `spec/models/crm_card_spec.rb`

**Interfaces:**
- Produces: `CrmCard` — `kind` (`lead`|`object`), `status` (`draft`|`needs_rework`|`pending_review`|`approved`|`exporting`|`exported`|`export_failed`), `export_mode` (`api`|`manual`), `payload` (jsonb Hash, ключи-строки), `check_errors` (jsonb Array `[{ 'field' =>, 'message' => }]`), `checked_at`, `submitted_at`, `reviewed_at`, `crm_id` (String), `exported_at`, `export_error` (Text), `lead_event`, `author` (`TelegramUser`), `reviewer` (`TelegramUser`), `transitions`. Константы `CrmCard::AUTHOR_EDITABLE = %w[draft needs_rework]`, `CrmCard::EXPORT_STALE_AFTER = 15.minutes`, `CrmCard::STATUS_LABELS` (Hash статус → «эмодзи Название»). Методы `#check_passed?`, `#export_stale?`, `#last_rework_comment`.
- Produces: `CrmCardTransition` — `crm_card`, `from_status`, `to_status`, `actor` (`TelegramUser`, nil — система), `comment`, `created_at`.

- [ ] **Step 1: Спека (красная)**

Создать `spec/models/crm_card_spec.rb`:

```ruby
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CrmCard do
  let(:author) { TelegramUser.create!(tg_user_id: 98_001, tg_username: 'irina', role: 'agent', status: 'active') }

  def lead_event
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'new',
                      anchor_topic_key: 'dispatcher', tg_chat_id: -100_1)
  end

  it 'по умолчанию — черновик с пустыми данными и без замечаний' do
    card = described_class.create!(kind: 'lead', author: author)

    expect(card).to be_status_draft
    expect(card).to be_kind_lead
    expect(card.payload).to eq({})
    expect(card.check_errors).to eq([])
  end

  it 'мягкое удаление прячет карточку из default scope' do
    card = described_class.create!(kind: 'object', author: author)
    card.update!(deleted_at: Time.current)

    expect(described_class.find_by(id: card.id)).to be_nil
    expect(described_class.unscoped.find_by(id: card.id)).to be_present
  end

  it 'одна карточка заявки на лид' do
    lead = lead_event
    described_class.create!(kind: 'lead', author: author, lead_event: lead)

    expect { described_class.create!(kind: 'lead', author: author, lead_event: lead) }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end

  it 'карточек объектов без лида может быть сколько угодно' do
    2.times { described_class.create!(kind: 'object', author: author) }

    expect(described_class.kind_object.count).to eq(2)
  end

  it 'check_passed? — только после проверки и без замечаний' do
    card = described_class.new(kind: 'lead', author: author)
    expect(card.check_passed?).to be(false)

    card.checked_at = Time.current
    expect(card.check_passed?).to be(true)

    card.check_errors = [{ 'field' => 'phone', 'message' => 'не заполнено' }]
    expect(card.check_passed?).to be(false)
  end

  it 'export_stale? — выгрузка, висящая дольше 15 минут' do
    card = described_class.create!(kind: 'lead', author: author, status: 'exporting')
    expect(card.export_stale?).to be(false)

    card.update_columns(updated_at: 16.minutes.ago)
    expect(card.export_stale?).to be(true)
  end

  it 'журнал упорядочен по времени, последний комментарий возврата доступен' do
    card = described_class.create!(kind: 'lead', author: author)
    card.transitions.create!(from_status: 'draft', to_status: 'pending_review', actor: author)
    card.transitions.create!(from_status: 'pending_review', to_status: 'needs_rework', actor: author,
                             comment: 'Уточни бюджет')

    expect(card.reload.transitions.map(&:to_status)).to eq(%w[pending_review needs_rework])
    expect(card.last_rework_comment).to eq('Уточни бюджет')
  end

  it 'у каждого статуса есть подпись' do
    expect(described_class::STATUS_LABELS.keys).to match_array(described_class.statuses.keys)
  end
end
```

- [ ] **Step 2: Прогнать — падает**

Run: `bin/rb --db bundle exec rspec spec/models/crm_card_spec.rb`
Expected: FAIL — `NameError: uninitialized constant CrmCard`.

- [ ] **Step 3: Миграция**

Создать `db/migrate/20260914120000_create_crm_cards.rb`:

```ruby
# frozen_string_literal: true

# Карточка для CRM проходит ручную модерацию, прежде чем попасть в Topnlab.
# Заявка с формы сайта бывает спамом, а удалять в CRM мы сознательно не
# умеем — мусор остался бы там навсегда (см. docs/superpowers/specs/
# 2026-09-14-crm-card-moderation-design.md).
#
# Уникальность «одна карточка заявки на лид» — индексом, а не валидацией:
# две кнопки, нажатые в одну секунду, валидация пропустила бы обе.
# Объекты без лида (заведены из меню) под индекс не попадают.
#
# Журнал переходов — отдельной таблицей: без него на вопрос «почему вернули
# на доработку» ответа нет, а комментарий модератора — главное в возврате.
class CreateCrmCards < ActiveRecord::Migration[8.1]
  def change
    create_table :crm_cards do |t|
      t.string     :kind,         null: false                      # lead | object
      t.string     :status,       null: false, default: 'draft'
      t.references :lead_event,   foreign_key: true
      t.references :author,       null: false, foreign_key: { to_table: :telegram_users }
      t.references :reviewer,     foreign_key: { to_table: :telegram_users }
      t.jsonb      :payload,      null: false, default: {}
      t.jsonb      :check_errors, null: false, default: []
      t.datetime   :checked_at
      t.datetime   :submitted_at
      t.datetime   :reviewed_at
      t.string     :export_mode                                    # api | manual
      t.string     :crm_id
      t.datetime   :exported_at
      t.text       :export_error
      t.datetime   :deleted_at
      t.timestamps
    end
    add_index :crm_cards, %i[status submitted_at]
    add_index :crm_cards, :deleted_at
    add_index :crm_cards, %i[lead_event_id kind], unique: true,
                                                   where: 'deleted_at IS NULL AND lead_event_id IS NOT NULL',
                                                   name: 'idx_crm_cards_one_per_lead'

    create_table :crm_card_transitions do |t|
      t.references :crm_card, null: false, foreign_key: true
      t.string     :from_status, null: false
      t.string     :to_status,   null: false
      t.references :actor, foreign_key: { to_table: :telegram_users }
      t.text       :comment
      t.datetime   :created_at, null: false
    end
  end
end
```

Run: `bin/rb --db bin/rails db:migrate`
Expected: миграция применена, `db/structure.sql` содержит `CREATE TABLE public.crm_cards` и `idx_crm_cards_one_per_lead`.

- [ ] **Step 4: Модели**

Создать `app/models/crm_card.rb`:

```ruby
# frozen_string_literal: true

# Карточка для выгрузки в CRM Topnlab после ручной модерации.
#
# Путь один для сайта и Telegram: ответственный связался с клиентом →
# дозаполнил карточку → машинная проверка → модерация → выгрузка. Статус
# меняет только CrmCards::Workflow — там же права и журнал.
#
# payload — значения полей по CrmCards::Schema, ключи — строки, значения уже
# нормализованы CrmCards::FieldValue. check_errors — итог CrmCards::Checker.
class CrmCard < ApplicationRecord
  belongs_to :lead_event, optional: true
  belongs_to :author,   class_name: 'TelegramUser'
  belongs_to :reviewer, class_name: 'TelegramUser', optional: true
  has_many :transitions, -> { order(:created_at, :id) },
           class_name: 'CrmCardTransition', dependent: :destroy, inverse_of: :crm_card

  enum :kind, {
    lead: 'lead',    # заявка покупателя/арендатора → clientorder через import_client
    object: 'object' # объект продавца/арендодателя → realty, до шлюза вносится вручную
  }, prefix: true

  enum :status, {
    draft: 'draft',                   # черновик — заполняет автор
    needs_rework: 'needs_rework',     # возвращена модератором с комментарием
    pending_review: 'pending_review', # на модерации
    approved: 'approved',             # одобрена, ждёт выгрузки
    exporting: 'exporting',           # выгрузка идёт прямо сейчас
    exported: 'exported',             # в CRM, crm_id известен
    export_failed: 'export_failed'    # выгрузка не удалась, ждёт повтора модератором
  }, prefix: true

  enum :export_mode, {
    api: 'api',      # через публичный API Topnlab
    manual: 'manual' # внесена руками в интерфейсе CRM, номер введён в боте
  }, prefix: true

  STATUS_LABELS = {
    'draft' => '📝 Черновик',
    'needs_rework' => '↩️ На доработке',
    'pending_review' => '⏳ На модерации',
    'approved' => '✅ Одобрена',
    'exporting' => '📤 Выгружается',
    'exported' => '🟢 В CRM',
    'export_failed' => '⚠️ Ошибка выгрузки'
  }.freeze

  # Автор правит карточку только здесь; на модерации поля правит модератор.
  AUTHOR_EDITABLE = %w[draft needs_rework].freeze
  # Выгрузка дольше этого считается прерванной: процесс упал между
  # захватом статуса и ответом CRM.
  EXPORT_STALE_AFTER = 15.minutes

  scope :not_deleted, -> { where(deleted_at: nil) }
  default_scope { not_deleted }

  validates :kind, :status, presence: true

  def check_passed?
    checked_at.present? && check_errors.blank?
  end

  def export_stale?
    status_exporting? && updated_at < EXPORT_STALE_AFTER.ago
  end

  def last_rework_comment
    transitions.reverse.find { |t| t.to_status == 'needs_rework' }&.comment
  end
end
```

Создать `app/models/crm_card_transition.rb`:

```ruby
# frozen_string_literal: true

# Журнал решений по карточке CRM: кто, когда, из какого статуса в какой и с
# каким комментарием. Только добавление: запись не правится и не удаляется,
# поэтому soft-delete ей не нужен — удалённая запись и есть потерянный ответ
# на «почему вернули на доработку».
class CrmCardTransition < ApplicationRecord
  belongs_to :crm_card, inverse_of: :transitions
  belongs_to :actor, class_name: 'TelegramUser', optional: true # nil — система (джоб выгрузки)

  validates :from_status, :to_status, presence: true
end
```

- [ ] **Step 5: Прогнать — зелёная**

Run: `bin/rb --db bundle exec rspec spec/models/crm_card_spec.rb`
Expected: `8 examples, 0 failures`.

- [ ] **Step 6: Линт и коммит**

Run: `bin/rb bundle exec rubocop -a app/models/crm_card.rb app/models/crm_card_transition.rb db/migrate/20260914120000_create_crm_cards.rb spec/models/crm_card_spec.rb`
Expected: `no offenses detected` (после автоисправлений).

```bash
git add db/migrate/20260914120000_create_crm_cards.rb db/structure.sql app/models/crm_card.rb \
        app/models/crm_card_transition.rb spec/models/crm_card_spec.rb
git commit -m "feat(crm_cards): модель карточки CRM и журнал решений"
```

### Task 2: Права из CRM

**Files:**
- Create: `config/crm_permissions.yml`
- Create: `app/services/crm_cards/permissions.rb`
- Create: `spec/support/crm_card_helpers.rb`
- Test: `spec/services/crm_cards/permissions_spec.rb`

**Interfaces:**
- Produces: `CrmCards::Permissions.for(tg_user) → Result`; `Result#can?(capability) → Boolean`, `Result#capabilities → Array<String>`, `Result#crm_user → User|nil`, `Result#position_title → String|nil`, `Result#denial → String|nil` (текст для сотрудника, без HTML).
- Produces: `CrmCards::Permissions.moderators → Array<TelegramUser>` (активные, с правом `moderate`, по `id`).
- Produces: `CrmCards::Permissions.positions → Hash{String => Hash}` (`crm_role_id` → `{ 'title', 'capabilities' }`); `CrmCards::Permissions::CAPABILITIES = %w[create_lead create_object moderate]`.
- Produces (спеки): `stub_crm_positions(positions = CRM_TEST_POSITIONS)`, `crm_staff(tg_user_id:, position: '89879', crm_status: 'active', role: 'agent', username: nil) → TelegramUser` — активный сотрудник с `dm_chat_id = tg_user_id`, `topnlab_user_id`, email и учёткой `User` с должностью. Должности: `'89884'` Генеральный директор (всё), `'89879'` Агент (заявки, объекты), `'89878'` Стажер (заявки); любая другая — «Конструктор» без прав.

- [ ] **Step 1: Помощник спек**

Создать `spec/support/crm_card_helpers.rb`:

```ruby
# frozen_string_literal: true

# Сотрудник с должностью в CRM — для спек карточек CRM. Права берутся из
# таблицы должностей, поэтому спеки подставляют свою и не зависят от
# содержимого config/crm_permissions.yml, которое правит руководитель.
module CrmCardHelpers
  CRM_TEST_POSITIONS = {
    '89884' => { 'title' => 'Генеральный директор', 'capabilities' => %w[create_lead create_object moderate] },
    '89879' => { 'title' => 'Агент', 'capabilities' => %w[create_lead create_object] },
    '89878' => { 'title' => 'Стажер', 'capabilities' => %w[create_lead] }
  }.freeze

  def stub_crm_positions(positions = CRM_TEST_POSITIONS)
    allow(CrmCards::Permissions).to receive(:positions).and_return(positions)
  end

  # @return [TelegramUser]
  def crm_staff(tg_user_id:, position: '89879', crm_status: 'active', role: 'agent', username: nil)
    crm_user_id = 700_000 + tg_user_id
    staff = TelegramUser.create!(tg_user_id: tg_user_id, tg_username: username, first_name: username || 'Сотрудник',
                                 role: role, status: 'active', dm_chat_id: tg_user_id,
                                 topnlab_user_id: crm_user_id, email: "staff#{tg_user_id}@victory.test")
    FactoryBot.create(:user, role: :agent, crm_user_id: crm_user_id, crm_role_id: position,
                             crm_role_name: CRM_TEST_POSITIONS.dig(position, 'title') || 'Конструктор',
                             crm_status: crm_status)
    staff
  end
end

RSpec.configure { |config| config.include CrmCardHelpers }
```

- [ ] **Step 2: Спека (красная)**

Создать `spec/services/crm_cards/permissions_spec.rb`:

```ruby
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CrmCards::Permissions do
  before { stub_crm_positions }

  it 'агент получает возможности своей должности в CRM' do
    perms = described_class.for(crm_staff(tg_user_id: 98_101))

    expect(perms.can?(:create_lead)).to be(true)
    expect(perms.can?(:create_object)).to be(true)
    expect(perms.can?(:moderate)).to be(false)
    expect(perms.position_title).to eq('Агент')
    expect(perms.denial).to be_nil
  end

  it 'роль в боте прав не даёт: директор бота с должностью «Конструктор» не модерирует' do
    perms = described_class.for(crm_staff(tg_user_id: 98_102, position: '1', role: 'director'))

    expect(perms.can?(:moderate)).to be(false)
    expect(perms.denial).to include('«Конструктор»', 'не выданы права')
  end

  it 'заблокированный в CRM теряет все права' do
    perms = described_class.for(crm_staff(tg_user_id: 98_103, crm_status: 'blocked'))

    expect(perms.can?(:create_lead)).to be(false)
    expect(perms.denial).to include('blocked')
  end

  it 'без привязки к CRM — подсказка про /whoami' do
    staff = TelegramUser.create!(tg_user_id: 98_104, status: 'active')

    expect(described_class.for(staff).denial).to include('/whoami')
  end

  it 'учётки нет в справочнике сотрудников — объяснение про ночную синхронизацию' do
    staff = TelegramUser.create!(tg_user_id: 98_105, status: 'active', topnlab_user_id: 123_456)

    expect(described_class.for(staff).denial).to include('ночью')
  end

  it 'две разные учётки CRM на одном телеграме — отказ, а не выбор наугад' do
    staff = crm_staff(tg_user_id: 98_106)
    create(:user, role: :agent, crm_user_id: 999_001, crm_role_id: '90328', crm_role_name: 'Юрист',
                  crm_status: 'blocked', telegram_user: staff)

    expect(described_class.for(staff).denial).to include('двум разным учёткам')
  end

  it 'неактивный в боте — без прав' do
    staff = crm_staff(tg_user_id: 98_107)
    staff.update!(status: 'inactive')

    expect(described_class.for(staff).can?(:create_lead)).to be(false)
  end

  it 'moderators — активные сотрудники с правом moderate' do
    boss = crm_staff(tg_user_id: 98_108, position: '89884')
    crm_staff(tg_user_id: 98_109)

    expect(described_class.moderators).to eq([boss])
  end

  it 'настоящая таблица читается и называет только известные возможности' do
    allow(described_class).to receive(:positions).and_call_original

    expect(described_class.positions).not_to be_empty
    described_class.positions.each_value do |position|
      expect(position['capabilities'] - described_class::CAPABILITIES).to be_empty
    end
  end
end
```

- [ ] **Step 3: Прогнать — падает**

Run: `bin/rb --db bundle exec rspec spec/services/crm_cards/permissions_spec.rb`
Expected: FAIL — `NameError: uninitialized constant CrmCards::Permissions`.

- [ ] **Step 4: Таблица должностей**

Создать `config/crm_permissions.yml`:

```yaml
# Права на карточки CRM по должности сотрудника в Topnlab.
#
# Ключ — id должности (users.crm_role_id), его приносит ночной
# TopnlabStaffSyncJob из getUsers. Название — только для людей: права
# выдаются по id, поэтому переименование должности в CRM их не ломает
# (bin/rails crm_cards:permissions предупредит о расхождении названий).
#
# Должность вне таблицы прав не имеет. Сменили сотруднику должность или
# уволили в CRM — после ночной синхронизации права меняются сами.
#
# Возможности: create_lead — заводить заявки; create_object — объекты;
# moderate — модерировать чужие карточки и выгружать в CRM.
#
# Значения на 14.09.26 — предложение, утверждает руководитель
# (docs/superpowers/specs/2026-09-14-crm-card-moderation-design.md, §10).
positions:
  '89884':
    title: Генеральный директор
    capabilities: [create_lead, create_object, moderate]
  '89879':
    title: Агент
    capabilities: [create_lead, create_object]
  '89878':
    title: Стажер
    capabilities: [create_lead]
  '90329':
    title: Стажер
    capabilities: [create_lead]
```

- [ ] **Step 5: Сервис прав**

Создать `app/services/crm_cards/permissions.rb`:

```ruby
# frozen_string_literal: true

module CrmCards
  # Права сотрудника на карточки CRM — наследуются из Topnlab.
  #
  # Источник — должность и статус учётки в CRM (users.crm_role_id,
  # crm_status). Роль в боте (telegram_users.role) прав не даёт: её ставят
  # руками через /promote, и на 14.09.26 она расходится с CRM.
  #
  # Публичный API Topnlab отдаёт должность, но не список прав роли. Поэтому
  # мост «должность → возможности» — config/crm_permissions.yml. Когда
  # появится шлюз к внутреннему API (crm_whoami с модулями роли), таблица
  # заменяется ответом CRM, а Result остаётся прежним.
  #
  # Отказ по умолчанию и всегда с причиной — сотрудник должен понять, что
  # чинить, а не гадать, почему кнопка не работает.
  class Permissions
    CAPABILITIES = %w[create_lead create_object moderate].freeze
    CONFIG_PATH = Rails.root.join('config/crm_permissions.yml').freeze

    Result = Struct.new(:capabilities, :crm_user, :position_title, :denial, keyword_init: true) do
      def can?(capability)
        denial.nil? && Array(capabilities).include?(capability.to_s)
      end
    end

    def self.for(tg_user)
      new(tg_user).call
    end

    # @return [Array<TelegramUser>]
    def self.moderators
      ::TelegramUser.active.where.not(topnlab_user_id: nil).order(:id).select { |staff| self.for(staff).can?(:moderate) }
    end

    # @return [Hash{String => Hash}] crm_role_id → { 'title' =>, 'capabilities' => }
    def self.positions
      YAML.load_file(CONFIG_PATH).fetch('positions', {}).transform_keys(&:to_s)
    end

    def initialize(tg_user)
      @tg_user = tg_user
    end

    def call
      return deny('Сотрудник не найден.') if @tg_user.nil?
      return deny('Аккаунт в боте не активен.') unless @tg_user.status == 'active'
      return deny('Нет привязки к CRM — выполни /whoami со своим рабочим email.') if @tg_user.topnlab_user_id.blank?

      crm_user = ::User.find_by(crm_user_id: @tg_user.topnlab_user_id)
      unless crm_user
        return deny('Учётки с этим id нет в справочнике сотрудников CRM — он обновляется ночью; ' \
                    'если завтра не появится, повтори /whoami.')
      end

      linked = ::User.find_by(telegram_user_id: @tg_user.id)
      if linked && linked.id != crm_user.id
        return deny('Телеграм привязан к двум разным учёткам CRM — права не выдаются, ' \
                    'пока руководитель не исправит привязку.', crm_user: crm_user)
      end

      return deny("Учётка в CRM не активна (#{crm_user.crm_status}).", crm_user: crm_user) unless crm_user.crm_status == 'active'

      position = self.class.positions[crm_user.crm_role_id.to_s]
      return deny("Должности «#{crm_user.crm_role_name}» в CRM не выданы права на карточки.", crm_user: crm_user) unless position

      Result.new(capabilities: Array(position['capabilities']).map(&:to_s) & CAPABILITIES,
                 crm_user: crm_user, position_title: crm_user.crm_role_name, denial: nil)
    end

    private

    def deny(reason, crm_user: nil)
      Result.new(capabilities: [], crm_user: crm_user, position_title: crm_user&.crm_role_name, denial: reason)
    end
  end
end
```

- [ ] **Step 6: Прогнать — зелёная**

Run: `bin/rb --db bundle exec rspec spec/services/crm_cards/permissions_spec.rb`
Expected: `9 examples, 0 failures`.

- [ ] **Step 7: Линт и коммит**

Run: `bin/rb bundle exec rubocop -a app/services/crm_cards/permissions.rb spec/services/crm_cards/permissions_spec.rb spec/support/crm_card_helpers.rb`
Expected: `no offenses detected`.

```bash
git add config/crm_permissions.yml app/services/crm_cards/permissions.rb \
        spec/support/crm_card_helpers.rb spec/services/crm_cards/permissions_spec.rb
git commit -m "feat(crm_cards): права на карточки из должности сотрудника в CRM"
```

### Task 3: Сводка прав для руководителя

**Files:**
- Create: `app/services/crm_cards/permissions_report.rb`
- Create: `lib/tasks/crm_cards.rake`
- Test: `spec/services/crm_cards/permissions_report_spec.rb`

**Interfaces:**
- Consumes: `CrmCards::Permissions.for`, `.moderators`, `.positions` (Task 2).
- Produces: `CrmCards::PermissionsReport.new.lines → Array<String>`; rake `crm_cards:permissions`. Без телефонов и email.

- [ ] **Step 1: Спека (красная)**

Создать `spec/services/crm_cards/permissions_report_spec.rb`:

```ruby
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CrmCards::PermissionsReport do
  before { stub_crm_positions }

  it 'по каждому активному сотруднику — роль в боте, должность в CRM и итог' do
    crm_staff(tg_user_id: 98_201, username: 'irina')
    crm_staff(tg_user_id: 98_202, username: 'sergey', position: '1', role: 'director')

    text = described_class.new.lines.join("\n")

    expect(text).to include('@irina · бот: agent · CRM: Агент → create_lead, create_object')
    expect(text).to include('@sergey · бот: director · CRM: Конструктор → нет прав:')
    expect(text).to include('Модераторов нет')
  end

  it 'перечисляет модераторов' do
    crm_staff(tg_user_id: 98_203, username: 'oksana', position: '89884', role: 'director')

    expect(described_class.new.lines).to include('Модераторы: @oksana')
  end

  it 'предупреждает, если должность переименовали в CRM' do
    staff = crm_staff(tg_user_id: 98_204, username: 'irina')
    User.find_by(crm_user_id: staff.topnlab_user_id).update_columns(crm_role_name: 'Агент по продажам')

    expect(described_class.new.lines.join("\n"))
      .to include('Должность 89879: в CRM «Агент по продажам», в config/crm_permissions.yml «Агент»')
  end

  it 'без телефонов и email' do
    crm_staff(tg_user_id: 98_205, username: 'irina')

    expect(described_class.new.lines.join("\n")).not_to include('@victory.test')
  end
end
```

- [ ] **Step 2: Прогнать — падает**

Run: `bin/rb --db bundle exec rspec spec/services/crm_cards/permissions_report_spec.rb`
Expected: FAIL — `NameError: uninitialized constant CrmCards::PermissionsReport`.

- [ ] **Step 3: Реализация**

Создать `app/services/crm_cards/permissions_report.rb`:

```ruby
# frozen_string_literal: true

module CrmCards
  # «Кто что может с карточками CRM» — для руководителя: перед включением
  # конвейера и после любой смены должностей. На 14.09.26 модерировать
  # было некому — учётка «Генеральный директор» не привязана к Telegram, —
  # и видно это было только отсюда.
  class PermissionsReport
    def lines
      out = ['Права на карточки CRM (должность в Topnlab → возможности)', '']
      ::TelegramUser.active.order(:id).each { |staff| out << staff_line(staff) }
      out << ''
      out << moderators_line
      out.concat(position_drift)
    end

    private

    def staff_line(staff)
      perms = Permissions.for(staff)
      verdict = perms.denial ? "нет прав: #{perms.denial}" : perms.capabilities.join(', ')
      "#{staff.mention} · бот: #{staff.role} · CRM: #{perms.position_title || '—'} → #{verdict}"
    end

    def moderators_line
      moderators = Permissions.moderators
      return '⚠️ Модераторов нет: карточки некому отправить на модерацию.' if moderators.empty?

      "Модераторы: #{moderators.map(&:mention).join(', ')}"
    end

    # Права выдаются по id должности, поэтому переименование в CRM их не
    # ломает, — но устаревшее название в таблице вводит в заблуждение.
    def position_drift
      known = Permissions.positions
      ::User.where(crm_role_id: known.keys).distinct.pluck(:crm_role_id, :crm_role_name).filter_map do |id, name|
        title = known.dig(id.to_s, 'title')
        "⚠️ Должность #{id}: в CRM «#{name}», в config/crm_permissions.yml «#{title}»" if title && title != name
      end
    end
  end
end
```

Создать `lib/tasks/crm_cards.rake`:

```ruby
# frozen_string_literal: true

namespace :crm_cards do
  desc 'Права сотрудников на карточки CRM: должность в Topnlab → возможности или причина отказа'
  task permissions: :environment do
    puts CrmCards::PermissionsReport.new.lines
  end
end
```

- [ ] **Step 4: Прогнать — зелёная**

Run: `bin/rb --db bundle exec rspec spec/services/crm_cards/permissions_report_spec.rb`
Expected: `4 examples, 0 failures`.

Run: `bin/rb --db bin/rails crm_cards:permissions`
Expected: заголовок «Права на карточки CRM…» и строка про модераторов (на пустой dev-базе — «⚠️ Модераторов нет»).

- [ ] **Step 5: Линт и коммит**

Run: `bin/rb bundle exec rubocop -a app/services/crm_cards/permissions_report.rb lib/tasks/crm_cards.rake spec/services/crm_cards/permissions_report_spec.rb`

```bash
git add app/services/crm_cards/permissions_report.rb lib/tasks/crm_cards.rake \
        spec/services/crm_cards/permissions_report_spec.rb
git commit -m "feat(crm_cards): сводка прав на карточки для руководителя"
```

### Task 4: Поля заявки, нормализация и машинная проверка

**Files:**
- Create: `app/services/crm_cards/schema.rb`
- Create: `app/services/crm_cards/field_value.rb`
- Create: `app/services/crm_cards/checker.rb`
- Test: `spec/services/crm_cards/field_value_spec.rb`
- Test: `spec/services/crm_cards/checker_spec.rb`

**Interfaces:**
- Consumes: `CrmCard` (Task 1).
- Produces: `CrmCards::Schema::Field` (`Struct`: `key, label, type, required, options, hint, min, max`; `type` ∈ `:string :text :phone :choice :integer :decimal`; `options` — `[[подпись, значение]]`). `Schema.for(kind) → Array<Field>` (в этой задаче знает только `'lead'`, на другом виде — `KeyError`), `Schema.field(kind, key) → Field|nil`, `Schema.option_label(field, value) → String|nil`. Константы `Schema::ACTIONS`, `Schema::REALTY_TYPES`.
- Produces: `CrmCards::FieldValue.normalize(field, raw) → [значение, ошибка|nil]`; также `.phone(raw)` с тем же контрактом. Нормальные формы: телефон `'7XXXXXXXXXX'`, целое — `Integer`, число — `Integer` если целое, иначе `Float` с 2 знаками. Тексты ошибок **не содержат ввода пользователя**.
- Produces: `CrmCards::Checker.call(card) → Array<Hash{'field' => String, 'message' => String}>`; поле `'lead'` — замечания к самому лиду.

- [ ] **Step 1: Спеки (красные)**

Создать `spec/services/crm_cards/field_value_spec.rb`:

```ruby
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CrmCards::FieldValue do
  def field(type, **opts)
    CrmCards::Schema::Field.new(key: 'x', label: 'X', type: type, required: true, **opts)
  end

  describe 'телефон' do
    it 'приводит российские форматы к 11 цифрам с 7' do
      expect(described_class.normalize(field(:phone), '+7 (910) 123-45-67')).to eq(['79101234567', nil])
      expect(described_class.normalize(field(:phone), '89101234567')).to eq(['79101234567', nil])
      expect(described_class.normalize(field(:phone), '910 123 45 67')).to eq(['79101234567', nil])
    end

    it 'короткий или иностранный номер — ошибка без эха ввода' do
      value, error = described_class.normalize(field(:phone), '<b>123</b>')

      expect(value).to be_nil
      expect(error).to include('11 цифр').and not_include('<b>')
    end
  end

  it 'число: пробелы и запятая, целое остаётся целым' do
    expect(described_class.normalize(field(:decimal), '5 500 000')).to eq([5_500_000, nil])
    expect(described_class.normalize(field(:decimal), '54,3')).to eq([54.3, nil])
    expect(described_class.normalize(field(:decimal), '0').last).to include('больше нуля')
    expect(described_class.normalize(field(:decimal), 'много').last).to include('Нужно число')
  end

  it 'целое' do
    expect(described_class.normalize(field(:integer), '3')).to eq([3, nil])
    expect(described_class.normalize(field(:integer), '3.5').last).to include('целое')
  end

  it 'текст: границы длины' do
    text = field(:text, min: 20, max: 30)

    expect(described_class.normalize(text, 'коротко').last).to include('от 20')
    expect(described_class.normalize(text, 'а' * 31).last).to include('влезает 30')
    expect(described_class.normalize(text, '  ровно двадцать символов  ').first).to eq('ровно двадцать символов')
  end

  it 'выбор — только из вариантов' do
    choice = field(:choice, options: [%w[Квартира flat]])

    expect(described_class.normalize(choice, 'flat')).to eq(['flat', nil])
    expect(described_class.normalize(choice, 'castle').last).to include('выбери кнопкой')
  end

  it 'пустое — ошибка' do
    expect(described_class.normalize(field(:string), '   ').last).to eq('Пустое значение.')
  end

  it 'нормализованное значение нормализуется в само себя' do
    expect(described_class.normalize(field(:phone), '79101234567')).to eq(['79101234567', nil])
    expect(described_class.normalize(field(:decimal), 54.3)).to eq([54.3, nil])
    expect(described_class.normalize(field(:integer), 12_345)).to eq([12_345, nil])
  end
end
```

`not_include` — составной отрицательный матчер; объявить в начале файла, сразу после `require 'rails_helper'`:

```ruby
RSpec::Matchers.define_negated_matcher :not_include, :include
```

Создать `spec/services/crm_cards/checker_spec.rb`:

```ruby
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CrmCards::Checker do
  let(:agent) { TelegramUser.create!(tg_user_id: 98_301, tg_username: 'irina', role: 'agent', status: 'active') }
  let(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1, assigned_to: agent,
                      first_contact_at: 1.hour.ago)
  end
  let(:valid_payload) do
    { 'name' => 'Анна', 'phone' => '79101234567', 'action' => 'sale', 'object_type' => 'flat',
      'comment' => 'Ищет двушку в Канищево до 6 млн, ипотека одобрена' }
  end

  def check(payload, lead_event: lead)
    described_class.call(CrmCard.new(kind: 'lead', author: agent, lead_event: lead_event, payload: payload))
  end

  it 'полная карточка по лиду после контакта — без замечаний' do
    expect(check(valid_payload)).to eq([])
  end

  it 'пустые обязательные поля перечислены, необязательные — нет' do
    fields = check({}).map { |e| e['field'] }

    expect(fields).to include('name', 'phone', 'action', 'object_type', 'comment')
    expect(fields).not_to include('realty_id')
  end

  it 'итог разговора короче 20 символов не проходит' do
    expect(check(valid_payload.merge('comment' => 'перезвонить'))).to contain_exactly(
      a_hash_including('field' => 'comment', 'message' => a_string_including('от 20'))
    )
  end

  it 'лид на стадии «новый» без отметки контакта — это и есть спам-фильтр' do
    lead.update!(current_stage: 'new', first_contact_at: nil)

    expect(check(valid_payload)).to contain_exactly(
      a_hash_including('field' => 'lead', 'message' => a_string_including('не связывались'))
    )
  end

  it 'отметка контакта без смены стадии тоже считается контактом' do
    lead.update!(current_stage: 'new', first_contact_at: 10.minutes.ago)

    expect(check(valid_payload)).to eq([])
  end

  it 'неназначенный, закрытый и тестовый лиды' do
    lead.update!(assigned_to: nil, current_stage: 'closed_lost', staff_test: true)

    expect(check(valid_payload).map { |e| e['message'] }).to include(
      a_string_including('никому не назначен'), a_string_including('Лид закрыт'), a_string_including('Тестовая')
    )
  end

  it 'клиент уже в CRM — вторую заявку не пропускает' do
    lead.lead_ref.update_columns(crm_id: '4455')

    expect(check(valid_payload).map { |e| e['message'] }).to include(a_string_including('4455'))
  end

  it 'карточка заявки без лида' do
    expect(check(valid_payload, lead_event: nil)).to contain_exactly(
      a_hash_including('field' => 'lead', 'message' => 'Карточка не привязана к лиду.')
    )
  end

  it 'повторная проверка сохранённых значений идемпотентна' do
    expect(check(valid_payload.merge('realty_id' => 12_345))).to eq([])
  end
end
```

- [ ] **Step 2: Прогнать — падают**

Run: `bin/rb --db bundle exec rspec spec/services/crm_cards/field_value_spec.rb spec/services/crm_cards/checker_spec.rb`
Expected: FAIL — `NameError: uninitialized constant CrmCards::Schema`.

- [ ] **Step 3: Схема**

Создать `app/services/crm_cards/schema.rb`:

```ruby
# frozen_string_literal: true

module CrmCards
  # Поля карточек — ровно то, что можно выгрузить в CRM, и ничего сверх.
  # Поле, которое некуда отправить, сотрудник заполнял бы зря.
  #
  # LEAD повторяет параметры Topnlab::Client#import_client.
  module Schema
    Field = Struct.new(:key, :label, :type, :required, :options, :hint, :min, :max, keyword_init: true)

    ACTIONS = [['Продажа / покупка', 'sale'], ['Аренда', 'rent']].freeze
    REALTY_TYPES = [
      %w[Квартира flat], %w[Комната room], %w[Дом house],
      %w[Коммерция commerce], %w[Участок land], %w[Гараж garage]
    ].freeze
    PHONE_HINT = 'Российский номер: +7 910 123-45-67 или 89101234567.'

    LEAD = [
      Field.new(key: 'name', label: 'Имя клиента', type: :string, required: true, max: 255),
      Field.new(key: 'phone', label: 'Телефон', type: :phone, required: true, hint: PHONE_HINT),
      Field.new(key: 'action', label: 'Что нужно клиенту', type: :choice, required: true, options: ACTIONS),
      Field.new(key: 'object_type', label: 'Тип объекта', type: :choice, required: true, options: REALTY_TYPES),
      Field.new(key: 'comment', label: 'Итог разговора с клиентом', type: :text, required: true, min: 20, max: 500,
                hint: 'Что ищет, бюджет, сроки. Это подтверждение, что с клиентом говорили: ' \
                      'без итога разговора карточка на модерацию не уйдёт.'),
      Field.new(key: 'realty_id', label: 'ID объекта в CRM', type: :integer, required: false,
                hint: 'Если клиент звонил по конкретному объекту — номер его карточки в Topnlab.')
    ].freeze

    KINDS = { 'lead' => LEAD }.freeze

    module_function

    # @raise [KeyError] на неизвестном виде карточки
    def for(kind)
      KINDS.fetch(kind.to_s)
    end

    def field(kind, key)
      self.for(kind).find { |f| f.key == key.to_s }
    end

    def option_label(field, value)
      Array(field.options).find { |_, v| v == value.to_s }&.first
    end
  end
end
```

- [ ] **Step 4: Нормализация**

Создать `app/services/crm_cards/field_value.rb`:

```ruby
# frozen_string_literal: true

module CrmCards
  # Нормализация одного значения поля. Контракт [значение, ошибка] — тот же,
  # что у Wizard::Flow#accept, поэтому мастер отдаёт ввод сюда без обёрток.
  #
  # Тексты ошибок не повторяют ввод: Wizard::Engine показывает их без
  # экранирования, и эхо «<b>…» сломало бы разметку сообщения.
  module FieldValue
    module_function

    # @return [Array(Object, String|nil)]
    def normalize(field, raw)
      return [nil, 'Пустое значение.'] if raw.nil? || raw.to_s.strip.empty?

      case field.type
      when :string, :text then text(field, raw)
      when :phone   then phone(raw)
      when :choice  then choice(field, raw)
      when :integer then integer(raw)
      when :decimal then decimal(raw)
      else [nil, 'Неизвестный тип поля.']
      end
    end

    def text(field, raw)
      value = field.type == :text ? raw.to_s.strip : raw.to_s.squish
      return [nil, "Слишком коротко: #{value.length} симв., нужно от #{field.min}."] if field.min && value.length < field.min
      return [nil, "Слишком длинно: #{value.length} симв., влезает #{field.max}."] if field.max && value.length > field.max

      [value, nil]
    end

    # Topnlab принимает ровно 11 цифр с ведущей 7 (Topnlab::Client#normalize_phone_11d).
    def phone(raw)
      digits = raw.to_s.gsub(/\D/, '')
      digits = "7#{digits}" if digits.length == 10
      digits = "7#{digits[1..]}" if digits.length == 11 && digits.start_with?('8')
      return [nil, 'Нужен российский номер из 11 цифр, начиная с 7 или 8.'] unless digits.match?(/\A7\d{10}\z/)

      [digits, nil]
    end

    def choice(field, raw)
      value = raw.to_s
      return [value, nil] if Array(field.options).any? { |_, v| v == value }

      [nil, 'Такого варианта нет — выбери кнопкой.']
    end

    def integer(raw)
      value = raw.to_s.strip
      return [nil, 'Нужно целое число цифрами.'] unless value.match?(/\A\d+\z/)
      return [nil, 'Число должно быть больше нуля.'] if value.to_i.zero?

      [value.to_i, nil]
    end

    def decimal(raw)
      value = raw.to_s.delete(" \u00A0").tr(',', '.') # пробел и неразрывный пробел: «5 500 000» из Telegram
      return [nil, 'Нужно число цифрами, например 54,3.'] unless value.match?(/\A\d+(\.\d+)?\z/)

      number = value.to_f.round(2)
      return [nil, 'Число должно быть больше нуля.'] unless number.positive?

      [(number % 1).zero? ? number.to_i : number, nil]
    end
  end
end
```

- [ ] **Step 5: Проверка**

Создать `app/services/crm_cards/checker.rb`:

```ruby
# frozen_string_literal: true

module CrmCards
  # Машинная проверка карточки перед модерацией. Модератор должен смотреть на
  # то, что машина проверить не может (правдоподобие, дубли), а не на пустые
  # поля и неверные телефоны.
  #
  # Перепроверка идемпотентна: значения в payload уже нормализованы, а
  # FieldValue.normalize отвечает на них тем же значением.
  class Checker
    def self.call(card)
      new(card).call
    end

    def initialize(card)
      @card = card
      @values = card.payload.to_h
    end

    # @return [Array<Hash{'field' => String, 'message' => String}>]
    def call
      errors = field_errors
      errors.concat(lead_rules) if @card.kind_lead?
      errors.map { |field, message| { 'field' => field, 'message' => message } }
    end

    private

    def field_errors
      Schema.for(@card.kind).filter_map do |field|
        raw = @values[field.key]
        if blank_value?(raw)
          [field.key, 'не заполнено'] if field.required
        else
          _, error = FieldValue.normalize(field, raw)
          [field.key, error] if error
        end
      end
    end

    # Заявка уходит в CRM только после живого контакта ответственного с
    # клиентом — это и отсекает спам с формы сайта.
    def lead_rules
      lead = @card.lead_event
      return [['lead', 'Карточка не привязана к лиду.']] unless lead

      errors = []
      errors << ['lead', 'Тестовая заявка сотрудника — в CRM не выгружается.'] if lead.staff_test?
      errors << ['lead', "Лид закрыт (#{lead.current_stage}) — выгружать нечего."] if lead.closed?
      errors << ['lead', 'Лид никому не назначен — сначала назначь ответственного.'] unless lead.assigned?
      if lead.first_contact_at.nil? && lead.current_stage == 'new'
        errors << ['lead', 'С клиентом ещё не связывались: лид на стадии «новый». Свяжись и отметь /stage контакт.']
      end
      crm_id = lead.lead_ref.try(:crm_id)
      errors << ['lead', "Клиент уже в CRM (заявка #{crm_id}) — вторая заявка не нужна."] if crm_id.present?
      errors
    end

    def blank_value?(raw)
      raw.nil? || raw.to_s.strip.empty?
    end
  end
end
```

- [ ] **Step 6: Прогнать — зелёные**

Run: `bin/rb --db bundle exec rspec spec/services/crm_cards/field_value_spec.rb spec/services/crm_cards/checker_spec.rb`
Expected: `17 examples, 0 failures`.

- [ ] **Step 7: Линт и коммит**

Run: `bin/rb bundle exec rubocop -a app/services/crm_cards/schema.rb app/services/crm_cards/field_value.rb app/services/crm_cards/checker.rb spec/services/crm_cards/field_value_spec.rb spec/services/crm_cards/checker_spec.rb`

```bash
git add app/services/crm_cards/schema.rb app/services/crm_cards/field_value.rb app/services/crm_cards/checker.rb \
        spec/services/crm_cards/field_value_spec.rb spec/services/crm_cards/checker_spec.rb
git commit -m "feat(crm_cards): поля заявки, нормализация и машинная проверка"
```

> **Конец стека A.** PR «данные и права» → CI → `/code-review` → правки.

---

## Стек B — конвейер

### Task 5: Выгрузка заявки в CRM и единственный путь записи

**Files:**
- Create: `app/services/crm_cards/lead_exporter.rb`
- Test: `spec/services/crm_cards/lead_exporter_spec.rb`
- Test: `spec/services/crm_cards/single_write_path_spec.rb`

**Interfaces:**
- Consumes: `CrmCard` (Task 1); `Topnlab::Client#import_client(phone:, name:, source:, realty_id: nil, comment: nil, action: nil, object_type: 'flat', to_number: nil) → Hash` (`'insertedId'`), `#transfer_client(order_id:, email:, stage_id: nil)` — существующие.
- Produces: `CrmCards::LeadExporter.new(topnlab: nil)`; `#call(card) → Outcome` (`Struct`: `crm_id` String, `warning` String|nil); бросает `Topnlab::Client::Error`, если заявка не создана.

- [ ] **Step 1: Спеки (красные)**

Создать `spec/services/crm_cards/lead_exporter_spec.rb`:

```ruby
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CrmCards::LeadExporter do
  let(:topnlab) { instance_double(Topnlab::Client) }
  let(:author) do
    TelegramUser.create!(tg_user_id: 98_401, tg_username: 'irina', status: 'active', email: 'irina@victory.test')
  end
  let(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1)
  end
  let(:card) do
    CrmCard.create!(kind: 'lead', author: author, lead_event: lead,
                    payload: { 'name' => 'Анна', 'phone' => '79101234567', 'action' => 'rent',
                               'object_type' => 'room', 'comment' => 'Ищет комнату у вокзала до 15 тысяч',
                               'realty_id' => 12_345 })
  end
  let(:exporter) { described_class.new(topnlab: topnlab) }

  it 'создаёт заявку и назначает автора карточки ответственным' do
    allow(topnlab).to receive(:import_client).and_return({ 'status' => 'ok', 'insertedId' => 4455 })
    allow(topnlab).to receive(:transfer_client).and_return({ 'status' => 'ok' })

    expect(exporter.call(card)).to have_attributes(crm_id: '4455', warning: nil)
    expect(topnlab).to have_received(:import_client).with(
      phone: '79101234567', name: 'Анна', source: 'site_form', realty_id: 12_345,
      comment: 'Ищет комнату у вокзала до 15 тысяч', action: 0, object_type: 'room'
    )
    expect(topnlab).to have_received(:transfer_client).with(order_id: 4455, email: 'irina@victory.test')
  end

  it 'продажа уходит как action: 1' do
    card.update!(payload: card.payload.merge('action' => 'sale'))
    allow(topnlab).to receive_messages(import_client: { 'status' => 'ok', 'insertedId' => 1 }, transfer_client: {})

    exporter.call(card)

    expect(topnlab).to have_received(:import_client).with(hash_including(action: 1))
  end

  it 'ответ без insertedId — ошибка, а не «успех без номера»' do
    allow(topnlab).to receive(:import_client).and_return({ 'status' => 'ok' })

    expect { exporter.call(card) }.to raise_error(Topnlab::Client::Error, /insertedId/)
  end

  it 'сбой назначения ответственного не отменяет выгрузку, а возвращается предупреждением' do
    allow(topnlab).to receive(:import_client).and_return({ 'status' => 'ok', 'insertedId' => 4455 })
    allow(topnlab).to receive(:transfer_client).and_raise(Topnlab::Client::Error, 'transferClient failed')

    outcome = exporter.call(card)

    expect(outcome.crm_id).to eq('4455')
    expect(outcome.warning).to include('ответственный не назначен')
  end

  it 'у автора нет email — предупреждение без вызова transfer_client' do
    author.update!(email: nil)
    allow(topnlab).to receive(:import_client).and_return({ 'status' => 'ok', 'insertedId' => 4455 })
    allow(topnlab).to receive(:transfer_client)

    expect(exporter.call(card).warning).to include('нет email')
    expect(topnlab).not_to have_received(:transfer_client)
  end
end
```

Создать `spec/services/crm_cards/single_write_path_spec.rb`:

```ruby
# frozen_string_literal: true

require 'rails_helper'

# Заявка попадает в CRM только через модерацию. Любой второй вызов
# import_client — обход модерации, даже если он «временный» или «для
# теста». До 14.09.26 метод не вызывался нигде, и заявки с сайта в CRM не
# уходили вовсе; теперь путь один, и спека держит его одним.
RSpec.describe 'единственный путь записи заявок в CRM' do
  it 'Topnlab::Client#import_client вызывается только из CrmCards::LeadExporter' do
    callers = Dir[Rails.root.join('app/**/*.rb')].select { |path| File.read(path).match?(/\.import_client\b/) }
                                                 .map { |path| Pathname(path).relative_path_from(Rails.root).to_s }

    expect(callers).to eq(['app/services/crm_cards/lead_exporter.rb'])
  end
end
```

- [ ] **Step 2: Прогнать — падают**

Run: `bin/rb --db bundle exec rspec spec/services/crm_cards/lead_exporter_spec.rb spec/services/crm_cards/single_write_path_spec.rb`
Expected: FAIL — `NameError: uninitialized constant CrmCards::LeadExporter`; вторая спека — `expected [...] got []`.

- [ ] **Step 3: Реализация**

Создать `app/services/crm_cards/lead_exporter.rb`:

```ruby
# frozen_string_literal: true

module CrmCards
  # Одобренная заявка → CRM через публичный API. Единственный вызов
  # import_client в приложении (single_write_path_spec).
  #
  # Ответственный в CRM — автор карточки: «под кем создали, тот и отвечает»
  # (ТЗ плагина topnlab-crm, §3.1).
  class LeadExporter
    Outcome = Struct.new(:crm_id, :warning, keyword_init: true)

    def initialize(topnlab: nil)
      @topnlab = topnlab
    end

    # @return [Outcome]
    # @raise [Topnlab::Client::Error] заявка не создана
    def call(card)
      values = card.payload
      response = topnlab.import_client(
        phone: values['phone'], name: values['name'], source: card.lead_event&.source.to_s,
        realty_id: values['realty_id'], comment: values['comment'],
        action: values['action'] == 'rent' ? 0 : 1, object_type: values['object_type']
      )
      crm_id = response['insertedId'].to_s
      raise Topnlab::Client::Error, 'importClient ответил ok без insertedId' if crm_id.blank?

      Outcome.new(crm_id: crm_id, warning: assign_responsible(crm_id, card.author))
    end

    private

    # Клиент Topnlab кидает на отсутствии ENV — создаём его только при
    # выгрузке, а не при построении Workflow в каждом мастере.
    def topnlab
      @topnlab ||= Topnlab::Client.new
    end

    # Заявка уже создана: сбой назначения выгрузку не отменяет, а
    # возвращается предупреждением — ответственного поставят в CRM руками.
    def assign_responsible(crm_id, author)
      return "у #{author.mention} нет email в привязке к CRM — ответственный не назначен" if author.email.blank?

      topnlab.transfer_client(order_id: crm_id.to_i, email: author.email)
      nil
    rescue Topnlab::Client::Error => e
      "ответственный не назначен: #{e.message.truncate(160)}"
    end
  end
end
```

- [ ] **Step 4: Прогнать — зелёные**

Run: `bin/rb --db bundle exec rspec spec/services/crm_cards/lead_exporter_spec.rb spec/services/crm_cards/single_write_path_spec.rb`
Expected: `6 examples, 0 failures`.

- [ ] **Step 5: Линт и коммит**

Run: `bin/rb bundle exec rubocop -a app/services/crm_cards/lead_exporter.rb spec/services/crm_cards/lead_exporter_spec.rb spec/services/crm_cards/single_write_path_spec.rb`

```bash
git add app/services/crm_cards/lead_exporter.rb spec/services/crm_cards/lead_exporter_spec.rb \
        spec/services/crm_cards/single_write_path_spec.rb
git commit -m "feat(crm_cards): выгрузка заявки в CRM — единственный путь import_client"
```

### Task 6: Карточка в личке — текст и кнопки под зрителя

**Files:**
- Create: `app/services/crm_cards/card_view.rb`
- Test: `spec/services/crm_cards/card_view_spec.rb`

**Interfaces:**
- Consumes: `CrmCard` (Task 1), `Permissions` (Task 2), `Schema` (Task 4).
- Produces: `CrmCards::CardView.render(card, viewer:) → { text: String, keyboard: Array<Array<Hash>> }` — ровно контракт `Wizard::Flow#finish`. `CardView.plain_value(field, value) → String` (без HTML — для текста кнопок). Кнопки: `wiz:s:crm_edit:<id>`, `crm_card:<id>:submit`, `wiz:s:crm_rework:<id>`, `wiz:s:crm_approve:<id>`, `wiz:s:crm_manual:<id>`, `crm_card:<id>:retry`. Константа `CardView::MANUAL_EXPORT_HINT`.

- [ ] **Step 1: Спека (красная)**

Создать `spec/services/crm_cards/card_view_spec.rb`:

```ruby
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CrmCards::CardView do
  before { stub_crm_positions }

  let!(:agent)    { crm_staff(tg_user_id: 98_501, username: 'irina') }
  let!(:director) { crm_staff(tg_user_id: 98_502, username: 'oksana', position: '89884', role: 'director') }
  let(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1, assigned_to: agent,
                      first_contact_at: 1.hour.ago)
  end
  let(:card) do
    CrmCard.create!(kind: 'lead', author: agent, lead_event: lead, checked_at: Time.current,
                    payload: { 'name' => 'Анна <b>', 'phone' => '79101234567', 'action' => 'sale',
                               'object_type' => 'flat', 'comment' => 'Ищет двушку до 6 млн, ипотека одобрена' })
  end

  def callbacks(view)
    view[:keyboard].flatten.map { |b| b[:callback_data] }
  end

  it 'текст: поля по-русски, телефон читаемо, пользовательский ввод экранирован' do
    text = described_class.render(card, viewer: agent)[:text]

    expect(text).to include("карточка ##{card.id}", "лид ##{lead.id}", 'Имя клиента: Анна &lt;b&gt;',
                            'Телефон: +7 910 123-45-67', 'Что нужно клиенту: Продажа / покупка',
                            '✅ пройдена', 'Автор: @irina')
    expect(text).not_to include('ID объекта в CRM')
  end

  it 'замечания проверки перечислены с названиями полей' do
    card.update!(check_errors: [{ 'field' => 'comment', 'message' => 'Слишком коротко' },
                                { 'field' => 'lead', 'message' => 'Лид закрыт' }])

    expect(described_class.render(card, viewer: agent)[:text])
      .to include('❌ 2 замеч.', '• Итог разговора с клиентом: Слишком коротко', '• Лид: Лид закрыт')
  end

  it 'черновик с пройденной проверкой: автору — править и отправить' do
    expect(callbacks(described_class.render(card, viewer: agent)))
      .to eq(["wiz:s:crm_edit:#{card.id}", "crm_card:#{card.id}:submit"])
  end

  it 'непройденная проверка — кнопки «На модерацию» нет' do
    card.update!(check_errors: [{ 'field' => 'phone', 'message' => 'не заполнено' }])

    expect(callbacks(described_class.render(card, viewer: agent))).to eq(["wiz:s:crm_edit:#{card.id}"])
  end

  it 'на модерации: модератору — править, вернуть, одобрить; автору — ничего' do
    card.update!(status: 'pending_review')

    expect(callbacks(described_class.render(card, viewer: director))).to eq(
      ["wiz:s:crm_edit:#{card.id}", "wiz:s:crm_rework:#{card.id}", "wiz:s:crm_approve:#{card.id}"]
    )
    expect(described_class.render(card, viewer: agent)[:keyboard]).to eq([])
  end

  it 'возврат на доработку показывает, кто и что просил' do
    card.update!(status: 'needs_rework', reviewer: director)
    card.transitions.create!(from_status: 'pending_review', to_status: 'needs_rework', actor: director,
                             comment: 'Уточни бюджет')

    expect(described_class.render(card, viewer: agent)[:text])
      .to include('Вернули на доработку', '@oksana', 'Уточни бюджет')
  end

  it 'сбой выгрузки: текст ошибки и совет проверить CRM; повтор — только модератору' do
    card.update!(status: 'export_failed', export_error: 'HTTP 502')

    expect(described_class.render(card, viewer: director)[:text]).to include('HTTP 502', 'найди клиента в CRM по телефону')
    expect(callbacks(described_class.render(card, viewer: director))).to eq(["crm_card:#{card.id}:retry"])
    expect(described_class.render(card, viewer: agent)[:keyboard]).to eq([])
  end

  it 'зависшая выгрузка: предупреждение и повтор модератору' do
    card.update!(status: 'exporting')
    card.update_columns(updated_at: 20.minutes.ago)

    expect(described_class.render(card, viewer: director)[:text]).to include('висит дольше 15 минут')
    expect(callbacks(described_class.render(card, viewer: director))).to eq(["crm_card:#{card.id}:retry"])
  end

  it 'сотрудник без прав видит карточку без кнопок' do
    auditor = crm_staff(tg_user_id: 98_503, position: '40')

    expect(described_class.render(card, viewer: auditor)[:keyboard]).to eq([])
  end
end
```

- [ ] **Step 2: Прогнать — падает**

Run: `bin/rb --db bundle exec rspec spec/services/crm_cards/card_view_spec.rb`
Expected: FAIL — `NameError: uninitialized constant CrmCards::CardView`.

- [ ] **Step 3: Реализация**

Создать `app/services/crm_cards/card_view.rb`:

```ruby
# frozen_string_literal: true

module CrmCards
  # Карточка CRM в личке: текст и кнопки под того, кто смотрит. Недоступной
  # зрителю кнопки нет вовсе — права всё равно перепроверяет Workflow, но
  # кнопка, которая всегда отвечает «нельзя», учит кнопки не нажимать.
  #
  # Только для личных сообщений: в тексте телефон клиента.
  module CardView
    KIND_TITLES = { 'lead' => 'Заявка в CRM', 'object' => 'Объект в CRM' }.freeze
    RETRY_HINT = 'Если это таймаут — сначала найди клиента в CRM по телефону: заявка могла создаться.'
    MANUAL_EXPORT_HINT = '📥 <b>Внеси объект в CRM вручную</b>: «Создать объект Продавца», поля — выше. ' \
                         'Копию договора приложи в CRM. Затем нажми «Внесено в CRM» и введи номер карточки.'

    module_function

    # @return [Hash] { text:, keyboard: } — контракт Wizard::Flow#finish
    def render(card, viewer:)
      { text: text(card), keyboard: keyboard(card, viewer, Permissions.for(viewer)) }
    end

    def text(card)
      lines = [header(card),
               "Статус: #{CrmCard::STATUS_LABELS[card.status]}",
               "Автор: #{escape(card.author.mention)} · обновлена #{Formatters::DateFormat.fmt_dt(card.updated_at)}",
               '']
      Schema.for(card.kind).each do |field|
        value = card.payload[field.key]
        next if value.nil? && !field.required

        lines << "#{field.label}: #{value.nil? ? '—' : escape(plain_value(field, value))}"
      end
      lines << ''
      lines.concat(check_lines(card))
      lines.concat(status_lines(card))
      lines.join("\n")
    end

    # Значение без HTML — для кнопок и для экранирования снаружи.
    def plain_value(field, value)
      case field.type
      when :phone   then format_phone(value.to_s)
      when :choice  then Schema.option_label(field, value) || value.to_s
      when :decimal then ActiveSupport::NumberHelper.number_to_delimited(value, delimiter: ' ', separator: ',')
      else value.to_s
      end
    end

    def keyboard(card, viewer, perms)
      return [] if perms.denial

      moderator = perms.can?(:moderate)
      author = card.author_id == viewer.id
      case card.status
      when 'draft', 'needs_rework' then author_rows(card) if author || moderator
      when 'pending_review' then moderator_rows(card) if moderator
      when 'approved' then [[button('📥 Внесено в CRM', "wiz:s:crm_manual:#{card.id}")]] if card.kind_object? && (author || moderator)
      when 'exporting' then [[button('🔁 Повторить выгрузку', "crm_card:#{card.id}:retry")]] if moderator && card.export_stale?
      when 'export_failed' then [[button('🔁 Повторить выгрузку', "crm_card:#{card.id}:retry")]] if moderator && card.kind_lead?
      end || []
    end

    def author_rows(card)
      rows = [[button('✏️ Изменить поле', "wiz:s:crm_edit:#{card.id}")]]
      rows << [button('📤 На модерацию', "crm_card:#{card.id}:submit")] if card.check_passed?
      rows
    end

    def moderator_rows(card)
      rows = [[button('✏️ Изменить поле', "wiz:s:crm_edit:#{card.id}"),
               button('↩️ На доработку', "wiz:s:crm_rework:#{card.id}")]]
      rows << [button('✅ Одобрить', "wiz:s:crm_approve:#{card.id}")] if card.check_passed?
      rows
    end

    def header(card)
      title = "📋 <b>#{KIND_TITLES[card.kind]} · карточка ##{card.id}</b>"
      card.lead_event_id ? "#{title} · лид ##{card.lead_event_id}" : title
    end

    def check_lines(card)
      return ['🔍 Машинная проверка ещё не запускалась.'] if card.checked_at.nil?
      return ['🔍 Машинная проверка: ✅ пройдена'] if card.check_errors.blank?

      ["🔍 Машинная проверка: ❌ #{card.check_errors.size} замеч."] +
        card.check_errors.map { |e| "• #{escape(error_label(card, e['field']))}: #{escape(e['message'])}" }
    end

    def status_lines(card)
      case card.status
      when 'needs_rework'
        ['', "↩️ <b>Вернули на доработку</b> #{escape(card.reviewer&.mention)}: #{escape(card.last_rework_comment)}"]
      when 'approved'
        card.kind_object? ? ['', MANUAL_EXPORT_HINT] : []
      when 'exporting'
        card.export_stale? ? ['', "⚠️ Выгрузка висит дольше 15 минут. #{RETRY_HINT}"] : []
      when 'exported'
        exported_lines(card)
      when 'export_failed'
        ['', "⚠️ <b>Выгрузка не удалась:</b> #{escape(card.export_error)}", "<i>#{RETRY_HINT}</i>"]
      else []
      end
    end

    def exported_lines(card)
      lines = ['', "🟢 В CRM: #{escape(card.crm_id)} · #{Formatters::DateFormat.fmt_dt(card.exported_at)}"]
      lines << "⚠️ #{escape(card.export_error)}" if card.export_error.present?
      lines
    end

    def error_label(card, key)
      return 'Лид' if key == 'lead'

      Schema.field(card.kind, key)&.label || key
    end

    def format_phone(digits)
      return digits unless digits.match?(/\A7\d{10}\z/)

      "+7 #{digits[1, 3]} #{digits[4, 3]}-#{digits[7, 2]}-#{digits[9, 2]}"
    end

    def button(text, callback_data)
      { text: text, callback_data: callback_data }
    end

    def escape(text)
      text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
    end
  end
end
```

- [ ] **Step 4: Прогнать — зелёная**

Run: `bin/rb --db bundle exec rspec spec/services/crm_cards/card_view_spec.rb`
Expected: `9 examples, 0 failures`.

- [ ] **Step 5: Линт и коммит**

Run: `bin/rb bundle exec rubocop -a app/services/crm_cards/card_view.rb spec/services/crm_cards/card_view_spec.rb`

```bash
git add app/services/crm_cards/card_view.rb spec/services/crm_cards/card_view_spec.rb
git commit -m "feat(crm_cards): карточка CRM в личке с кнопками под роль из CRM"
```

### Task 7: Уведомления участникам

**Files:**
- Create: `app/services/crm_cards/notifier.rb`
- Test: `spec/services/crm_cards/notifier_spec.rb`

**Interfaces:**
- Consumes: `CardView.render` (Task 6), `Permissions.moderators` (Task 2), `Telegram::WorkBot::LeadAnnouncer.refresh!(lead_event, client:)` — существующий.
- Produces: `CrmCards::Notifier.new(client: nil)` с методами `#submitted(card, moderators:)`, `#returned(card, comment:)`, `#approved(card)`, `#exported(card, warning: nil)`, `#export_failed(card)`. Ни один не бросает на сбое Telegram. Каждый перерисовывает карточку лида, если она есть.

- [ ] **Step 1: Спека (красная)**

Создать `spec/services/crm_cards/notifier_spec.rb`:

```ruby
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CrmCards::Notifier do
  let(:sent) { [] }
  let(:tg_client) do
    client = instance_double(Telegram::Client)
    allow(client).to receive(:send_message) do |text, **opts|
      sent << { text: text, chat_id: opts[:chat_id], keyboard: opts.dig(:reply_markup, :inline_keyboard) || [] }
      { 'message_id' => 1 }
    end
    allow(client).to receive(:edit_message_text).and_return(true)
    client
  end
  let(:notifier) { described_class.new(client: tg_client) }

  before { stub_crm_positions }

  let!(:agent)    { crm_staff(tg_user_id: 98_601, username: 'irina') }
  let!(:director) { crm_staff(tg_user_id: 98_602, username: 'oksana', position: '89884', role: 'director') }
  let(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1, anchor_message_id: 777,
                      assigned_to: agent, first_contact_at: 1.hour.ago)
  end
  let(:card) do
    CrmCard.create!(kind: 'lead', author: agent, lead_event: lead, status: 'pending_review', checked_at: Time.current,
                    payload: { 'name' => 'Анна', 'phone' => '79101234567', 'action' => 'sale',
                               'object_type' => 'flat', 'comment' => 'Ищет двушку до 6 млн, ипотека одобрена' })
  end

  it 'на модерацию: модератору в личку карточка с кнопками решения; карточка лида перерисована' do
    notifier.submitted(card, moderators: [director])

    dm = sent.find { |m| m[:chat_id] == director.dm_chat_id }
    expect(dm[:text]).to include('На модерацию', '@irina', 'Телефон: +7 910 123-45-67')
    expect(dm[:keyboard].flatten.map { |b| b[:callback_data] }).to include("wiz:s:crm_approve:#{card.id}")
    expect(tg_client).to have_received(:edit_message_text).with(anything, hash_including(chat_id: -100_1, message_id: 777))
  end

  it 'ни одному модератору не написать — автор узнаёт об этом сразу' do
    director.update!(dm_chat_id: nil)

    notifier.submitted(card, moderators: [director])

    expect(sent.map { |m| m[:chat_id] }).to eq([agent.dm_chat_id])
    expect(sent.last[:text]).to include('ни одному модератору')
  end

  it 'возврат: автору комментарий и карточка с кнопкой правки' do
    card.update!(status: 'needs_rework', reviewer: director)
    card.transitions.create!(from_status: 'pending_review', to_status: 'needs_rework', actor: director,
                             comment: 'Уточни бюджет')

    notifier.returned(card, comment: 'Уточни бюджет')

    expect(sent.last[:chat_id]).to eq(agent.dm_chat_id)
    expect(sent.last[:text]).to include('вернулась на доработку', 'Уточни бюджет')
    expect(sent.last[:keyboard].flatten.map { |b| b[:callback_data] }).to include("wiz:s:crm_edit:#{card.id}")
  end

  it 'выгрузка: автору и модератору номер в CRM и предупреждение' do
    card.update!(status: 'exported', crm_id: '4455', reviewer: director)

    notifier.exported(card, warning: 'ответственный не назначен')

    expect(sent.map { |m| m[:chat_id] }).to contain_exactly(agent.dm_chat_id, director.dm_chat_id)
    expect(sent.first[:text]).to include('4455', 'ответственный не назначен')
  end

  it 'сбой выгрузки: модератору кнопка повтора, автору — что повтор у модератора' do
    card.update!(status: 'export_failed', export_error: 'HTTP 502')

    notifier.export_failed(card)

    to_director = sent.find { |m| m[:chat_id] == director.dm_chat_id }
    expect(to_director[:keyboard].flatten.map { |b| b[:callback_data] }).to eq(["crm_card:#{card.id}:retry"])
    expect(sent.find { |m| m[:chat_id] == agent.dm_chat_id }[:text]).to include('кнопка повтора')
  end

  it 'сбой отправки в Telegram не роняет конвейер' do
    allow(tg_client).to receive(:send_message).and_raise(Telegram::Client::Error, 'bot was blocked')

    expect { notifier.returned(card, comment: 'Уточни бюджет') }.not_to raise_error
  end
end
```

- [ ] **Step 2: Прогнать — падает**

Run: `bin/rb --db bundle exec rspec spec/services/crm_cards/notifier_spec.rb`
Expected: FAIL — `NameError: uninitialized constant CrmCards::Notifier`.

- [ ] **Step 3: Реализация**

Создать `app/services/crm_cards/notifier.rb`:

```ruby
# frozen_string_literal: true

module CrmCards
  # Уведомления конвейера карточек CRM — только в личку. В группу карточка
  # не уходит: там телефон клиента увидят все. Под карточкой лида в группе
  # меняется лишь кнопка со статусом (LeadAnnouncer.refresh!).
  #
  # Сбой Telegram конвейер не роняет: карточка уже в новом статусе, и
  # сотрудник увидит её через /cards.
  class Notifier
    def initialize(client: nil)
      @client = client
    end

    def submitted(card, moderators:)
      delivered = moderators.count { |moderator| deliver(moderator, "📥 <b>На модерацию</b> от #{escape(card.author.mention)}", card) }
      if delivered.zero?
        dm(card.author, '⚠️ Карточка на модерации, но ни одному модератору не удалось написать в личку. ' \
                        'Пусть директор откроет чат с ботом, нажмёт «Start» и наберёт /cards.')
      end
      refresh_lead_anchor(card)
    end

    def returned(card, comment:)
      deliver(card.author, "↩️ <b>Карточка ##{card.id} вернулась на доработку</b>: #{escape(comment)}", card)
      refresh_lead_anchor(card)
    end

    def approved(card)
      header = if card.kind_lead?
                 "✅ <b>Карточка ##{card.id} одобрена</b> #{escape(card.reviewer&.mention)} — выгружаю в CRM."
               else
                 "✅ <b>Объект одобрен</b> #{escape(card.reviewer&.mention)} — внеси его в CRM и отметь номер карточки."
               end
      deliver(card.author, header, card)
      refresh_lead_anchor(card)
    end

    def exported(card, warning: nil)
      text = "🟢 <b>Карточка ##{card.id} в CRM:</b> #{escape(card.crm_id)}"
      text += "\n⚠️ #{escape(warning)}" if warning.present?
      [card.author, card.reviewer].compact.uniq(&:id).each { |user| dm(user, text) }
      refresh_lead_anchor(card)
    end

    def export_failed(card)
      Permissions.moderators.each { |moderator| deliver(moderator, "⚠️ <b>Выгрузка карточки ##{card.id} не удалась</b>", card) }
      dm(card.author, "⚠️ Выгрузка карточки ##{card.id} в CRM не удалась — у модератора кнопка повтора.")
      refresh_lead_anchor(card)
    end

    private

    # @return [Boolean] доставлено ли
    def deliver(user, header, card)
      view = CardView.render(card, viewer: user)
      dm(user, "#{header}\n\n#{view[:text]}", keyboard: view[:keyboard])
    end

    def dm(user, text, keyboard: nil)
      return false unless user&.can_dm?

      opts = { chat_id: user.dm_chat_id, parse_mode: 'HTML' }
      opts[:reply_markup] = { inline_keyboard: keyboard } if keyboard.present?
      client.send_message(text, **opts)
      true
    rescue Telegram::Client::Error => e
      Rails.logger.warn("[CrmCards::Notifier] DM to #{user.mention} failed: #{e.message}")
      false
    end

    def refresh_lead_anchor(card)
      return unless card.lead_event

      Telegram::WorkBot::LeadAnnouncer.refresh!(card.lead_event, client: client)
    end

    def client
      @client ||= Telegram::Client.new
    end

    def escape(text)
      text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
    end
  end
end
```

`LeadAnnouncer.refresh!` сам ловит любые исключения и возвращает `false`, поэтому отдельный `rescue` вокруг него не нужен.

- [ ] **Step 4: Прогнать — зелёная**

Run: `bin/rb --db bundle exec rspec spec/services/crm_cards/notifier_spec.rb`
Expected: `6 examples, 0 failures`.

- [ ] **Step 5: Линт и коммит**

Run: `bin/rb bundle exec rubocop -a app/services/crm_cards/notifier.rb spec/services/crm_cards/notifier_spec.rb`

```bash
git add app/services/crm_cards/notifier.rb spec/services/crm_cards/notifier_spec.rb
git commit -m "feat(crm_cards): уведомления участникам модерации в личку"
```

### Task 8: Переходы статусов и джоб выгрузки

**Files:**
- Create: `app/services/crm_cards/workflow.rb`
- Create: `app/jobs/crm_cards/export_job.rb`
- Test: `spec/services/crm_cards/workflow_spec.rb`
- Test: `spec/jobs/crm_cards/export_job_spec.rb`

**Interfaces:**
- Consumes: `Permissions` (Task 2), `Schema`, `Checker` (Task 4), `LeadExporter` (Task 5), `Notifier` (Task 7).
- Produces: `CrmCards::Workflow.new(notifier: nil, exporter: nil)`; `Workflow::Result` (`Struct`: `ok`, `card`, `error`; `#ok?`). Методы, каждый `→ Result`:
  - `#upsert_lead_card!(lead:, actor:, values:)` — создать/дополнить карточку заявки по лиду; ответственный по лиду перенимает черновик;
  - `#create_object_card!(actor:, values:)` — новая карточка объекта;
  - `#update_fields!(card, values, actor:)` — `values` Hash ключ → нормализованное значение; `nil` удаляет поле;
  - `#submit!(card, actor:)`, `#return_for_rework!(card, actor:, comment:)`, `#approve!(card, actor:)`;
  - `#export!(card)` — только для джоба; `#record_export!(card, crm_id:, mode:, actor: nil, warning: nil)` — `mode` `'api'`|`'manual'`; `#retry_export!(card, actor:)`.
- Produces: `#can_edit?(card, actor, perms = Permissions.for(actor)) → Boolean`, `#edit_denial(card, perms) → String`.
- Produces: `CrmCards::ExportJob.perform_later(card_id)`.

- [ ] **Step 1: Спеки (красные)**

Создать `spec/services/crm_cards/workflow_spec.rb`:

```ruby
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CrmCards::Workflow do
  let(:notifier) do
    instance_double(CrmCards::Notifier, submitted: nil, returned: nil, approved: nil, exported: nil, export_failed: nil)
  end
  let(:exporter) { instance_double(CrmCards::LeadExporter) }
  let(:workflow) { described_class.new(notifier: notifier, exporter: exporter) }

  before { stub_crm_positions }

  let!(:agent)    { crm_staff(tg_user_id: 98_701, username: 'irina') }
  let!(:director) { crm_staff(tg_user_id: 98_702, username: 'oksana', position: '89884', role: 'director') }
  let(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1, assigned_to: agent,
                      first_contact_at: 1.hour.ago)
  end
  let(:values) do
    { 'name' => 'Анна', 'phone' => '79101234567', 'action' => 'sale', 'object_type' => 'flat',
      'comment' => 'Ищет двушку в Канищево до 6 млн, ипотека одобрена' }
  end

  def filled_card
    workflow.upsert_lead_card!(lead: lead, actor: agent, values: values).card
  end

  describe '#upsert_lead_card!' do
    it 'создаёт черновик с автором и итогом проверки' do
      result = workflow.upsert_lead_card!(lead: lead, actor: agent, values: values)

      expect(result).to be_ok
      expect(result.card).to have_attributes(status: 'draft', author_id: agent.id)
      expect(result.card.check_passed?).to be(true)
    end

    it 'дописывает поля в тот же черновик и не плодит вторую карточку' do
      workflow.upsert_lead_card!(lead: lead, actor: agent, values: values.except('comment'))

      expect { workflow.upsert_lead_card!(lead: lead, actor: agent, values: { 'comment' => values['comment'] }) }
        .not_to change(CrmCard, :count)
      expect(CrmCard.last.payload).to include('name' => 'Анна', 'comment' => values['comment'])
    end

    it 'должность без права create_lead — отказ, карточки нет' do
      auditor = crm_staff(tg_user_id: 98_703, position: '40')

      result = workflow.upsert_lead_card!(lead: lead, actor: auditor, values: values)

      expect(result.error).to include('не выданы права')
      expect(CrmCard.count).to eq(0)
    end

    it 'новый ответственный по лиду перенимает черновик' do
      filled_card
      petr = crm_staff(tg_user_id: 98_704, username: 'petr')
      lead.update!(assigned_to: petr)

      result = workflow.upsert_lead_card!(lead: lead, actor: petr, values: {})

      expect(result).to be_ok
      expect(result.card.author).to eq(petr)
    end

    it 'посторонний сотрудник чужой черновик не правит' do
      card = filled_card
      petr = crm_staff(tg_user_id: 98_705, username: 'petr')

      expect(workflow.update_fields!(card, { 'name' => 'Пётр' }, actor: petr).error).to include('ведёт @irina')
    end
  end

  describe '#submit!' do
    it 'проверенную карточку отправляет на модерацию и зовёт модераторов' do
      card = filled_card

      expect(workflow.submit!(card, actor: agent)).to be_ok
      expect(card.reload).to be_status_pending_review
      expect(card.submitted_at).to be_present
      expect(card.transitions.last).to have_attributes(from_status: 'draft', to_status: 'pending_review', actor_id: agent.id)
      expect(notifier).to have_received(:submitted).with(card, moderators: [director])
    end

    it 'непройденная проверка — остаётся черновиком' do
      card = workflow.upsert_lead_card!(lead: lead, actor: agent, values: values.merge('comment' => 'коротко')).card

      expect(workflow.submit!(card, actor: agent).error).to include('Машинная проверка не пройдена')
      expect(card.reload).to be_status_draft
      expect(notifier).not_to have_received(:submitted)
    end

    it 'модераторов нет — не отправляет в пустоту' do
      director.update!(status: 'inactive')

      expect(workflow.submit!(filled_card, actor: agent).error).to include('Модераторов')
    end
  end

  describe 'решения модератора' do
    let(:card) { filled_card.tap { |c| workflow.submit!(c, actor: agent) }.reload }

    it 'агент одобрить не может' do
      expect(workflow.approve!(card, actor: agent).error).to include('только модератор')
    end

    it 'возврат на доработку требует комментарий и пишет его в журнал' do
      expect(workflow.return_for_rework!(card, actor: director, comment: ' ').error).to include('комментарий')

      expect(workflow.return_for_rework!(card, actor: director, comment: 'Уточни бюджет')).to be_ok
      expect(card.reload).to be_status_needs_rework
      expect(card.last_rework_comment).to eq('Уточни бюджет')
      expect(notifier).to have_received(:returned).with(card, comment: 'Уточни бюджет')
    end

    it 'после доработки карточку снова можно отправить' do
      workflow.return_for_rework!(card, actor: director, comment: 'Уточни бюджет')
      workflow.update_fields!(card.reload, { 'comment' => 'Бюджет 6 млн, ипотека одобрена в Сбере' }, actor: agent)

      expect(workflow.submit!(card.reload, actor: agent)).to be_ok
    end

    it 'на модерации поле правит модератор, автор — нет' do
      expect(workflow.update_fields!(card, { 'name' => 'Анна Смирнова' }, actor: agent).error).to include('на модерации')
      expect(workflow.update_fields!(card, { 'name' => 'Анна Смирнова' }, actor: director)).to be_ok
    end

    it 'одобрение заявки ставит выгрузку в очередь' do
      expect { workflow.approve!(card, actor: director) }.to have_enqueued_job(CrmCards::ExportJob).with(card.id)
      expect(card.reload).to have_attributes(status: 'approved', reviewer_id: director.id, export_mode: 'api')
      expect(notifier).to have_received(:approved).with(card)
    end

    it 'лид закрылся, пока карточка ждала, — одобрить нельзя' do
      lead.update!(current_stage: 'closed_lost')

      expect(workflow.approve!(card, actor: director).error).to include('больше не проходит')
      expect(card.reload).to be_status_pending_review
    end
  end

  describe '#export!' do
    let(:card) do
      filled_card.tap { |c| workflow.submit!(c, actor: agent) }.reload
                 .tap { |c| workflow.approve!(c, actor: director) }.reload
    end
    let(:outcome) { CrmCards::LeadExporter::Outcome.new(crm_id: '4455', warning: nil) }

    it 'успешная выгрузка: номер в карточке и у заявки с сайта, журнал' do
      allow(exporter).to receive(:call).and_return(outcome)

      expect(workflow.export!(card)).to be_ok
      expect(card.reload).to have_attributes(status: 'exported', crm_id: '4455')
      expect(card.transitions.map(&:to_status)).to end_with('exporting', 'exported')
      expect(lead.lead_ref.reload.crm_id).to eq('4455')
      expect(notifier).to have_received(:exported).with(card, warning: nil)
    end

    it 'второй запуск не выгружает повторно' do
      allow(exporter).to receive(:call).and_return(outcome)

      workflow.export!(card)

      expect(workflow.export!(card.reload)).not_to be_ok
      expect(exporter).to have_received(:call).once
    end

    it 'ошибка CRM — export_failed с текстом; повтор только модератором' do
      allow(exporter).to receive(:call).and_raise(Topnlab::Client::Error, 'POST /call/main/importClient/: HTTP 502')

      workflow.export!(card)

      expect(card.reload).to have_attributes(status: 'export_failed', export_error: a_string_including('HTTP 502'))
      expect(notifier).to have_received(:export_failed).with(card)
      expect(workflow.retry_export!(card, actor: agent).error).to include('только модератор')
      expect { workflow.retry_export!(card, actor: director) }.to have_enqueued_job(CrmCards::ExportJob).with(card.id)
      expect(card.reload).to be_status_approved
    end
  end
end
```

Создать `spec/jobs/crm_cards/export_job_spec.rb`:

```ruby
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CrmCards::ExportJob do
  it 'передаёт карточку конвейеру' do
    card = instance_double(CrmCard)
    workflow = instance_double(CrmCards::Workflow, export!: nil)
    allow(CrmCard).to receive(:find_by).with(id: 42).and_return(card)
    allow(CrmCards::Workflow).to receive(:new).and_return(workflow)

    described_class.perform_now(42)

    expect(workflow).to have_received(:export!).with(card)
  end

  it 'неожиданная ошибка не пробрасывается: автоповтор ApplicationJob завёл бы вторую заявку' do
    allow(CrmCard).to receive(:find_by).and_raise(StandardError, 'boom')

    expect { described_class.perform_now(42) }.not_to raise_error
  end
end
```

- [ ] **Step 2: Прогнать — падают**

Run: `bin/rb --db bundle exec rspec spec/services/crm_cards/workflow_spec.rb spec/jobs/crm_cards/export_job_spec.rb`
Expected: FAIL — `NameError: uninitialized constant CrmCards::Workflow`.

- [ ] **Step 3: Workflow**

Создать `app/services/crm_cards/workflow.rb`:

```ruby
# frozen_string_literal: true

module CrmCards
  # Все переходы карточки CRM — только здесь. Мастера, кнопки и команды
  # вызывают эти методы и статус сами не трогают: права из CRM, допустимость
  # перехода и журнал проверяются в одном месте.
  #
  # Методы возвращают Result, а не бросают: отказ по правам — штатный ответ
  # сотруднику, а не авария. Уведомления уходят после снятия блокировки
  # строки, чтобы медленный Telegram не держал её.
  class Workflow
    Result = Struct.new(:ok, :card, :error, keyword_init: true) do
      def ok?
        ok == true
      end
    end

    def initialize(notifier: nil, exporter: nil)
      @notifier = notifier
      @exporter = exporter
    end

    def upsert_lead_card!(lead:, actor:, values:)
      perms = Permissions.for(actor)
      return deny(perms.denial) if perms.denial
      return deny('Твоей должности в CRM не выдано право заводить заявки.') unless perms.can?(:create_lead)

      card = CrmCard.kind_lead.find_or_initialize_by(lead_event_id: lead.id)
      save_values(card, values, actor: actor, perms: perms, take_over: lead.assigned_to_id == actor.id)
    rescue ActiveRecord::RecordNotUnique
      deny('Карточку по этому лиду только что создал другой сотрудник — открой её кнопкой ещё раз.')
    end

    def create_object_card!(actor:, values:)
      perms = Permissions.for(actor)
      return deny(perms.denial) if perms.denial
      return deny('Твоей должности в CRM не выдано право заводить объекты.') unless perms.can?(:create_object)

      save_values(CrmCard.new(kind: 'object'), values, actor: actor, perms: perms)
    end

    def update_fields!(card, values, actor:)
      save_values(card, values, actor: actor, perms: Permissions.for(actor))
    end

    def submit!(card, actor:)
      moderators = []
      result = card.with_lock do
        perms = Permissions.for(actor)
        next deny(edit_denial(card, perms)) unless CrmCard::AUTHOR_EDITABLE.include?(card.status) && can_edit?(card, actor, perms)

        refresh_check(card)
        unless card.check_passed?
          card.save!
          next deny("Машинная проверка не пройдена: #{card.check_errors.size} замеч. — поправь поля и отправь снова.")
        end

        moderators = Permissions.moderators
        next deny('Модераторов с доступом к CRM нет — карточку некому проверить. Сообщи директору.') if moderators.empty?

        transition!(card, to: 'pending_review', actor: actor)
        card.update!(submitted_at: Time.current)
        ok(card)
      end
      notifier.submitted(card, moderators: moderators) if result.ok?
      result
    end

    def return_for_rework!(card, actor:, comment:)
      text = comment.to_s.strip
      result = card.with_lock do
        next deny(moderator_denial(actor, 'Возвращать на доработку')) unless moderator?(actor)
        next deny(not_pending(card)) unless card.status_pending_review?
        next deny('Нужен комментарий: что доработать.') if text.empty?

        transition!(card, to: 'needs_rework', actor: actor, comment: text)
        card.update!(reviewer: actor, reviewed_at: Time.current)
        ok(card)
      end
      notifier.returned(card, comment: text) if result.ok?
      result
    end

    def approve!(card, actor:)
      result = card.with_lock do
        next deny(moderator_denial(actor, 'Одобрять')) unless moderator?(actor)
        next deny(not_pending(card)) unless card.status_pending_review?

        # Модератор мог поправить поля, а лид — закрыться, пока карточка ждала.
        refresh_check(card)
        unless card.check_passed?
          card.save!
          next deny("Машинная проверка больше не проходит: #{card.check_errors.size} замеч. — " \
                    'поправь поля или верни на доработку.')
        end

        transition!(card, to: 'approved', actor: actor)
        card.update!(reviewer: actor, reviewed_at: Time.current, export_mode: card.kind_lead? ? 'api' : 'manual')
        ok(card)
      end
      if result.ok?
        ExportJob.perform_later(card.id) if card.kind_lead?
        notifier.approved(card)
      end
      result
    end

    # Только для ExportJob. Захват approved → exporting атомарный: двойной
    # запуск джоба (ретрай Sidekiq, два процесса) не заведёт две заявки.
    def export!(card)
      claimed = CrmCard.where(id: card.id, kind: 'lead', status: 'approved')
                       .update_all(status: 'exporting', updated_at: Time.current)
      return deny('Карточка не ждёт выгрузки: не одобрена или её уже выгружает другой процесс.') unless claimed == 1

      card.reload
      card.transitions.create!(from_status: 'approved', to_status: 'exporting')
      begin
        outcome = exporter.call(card)
      rescue StandardError => e
        return fail_export!(card, error: "#{e.class}: #{e.message}")
      end
      record_export!(card, crm_id: outcome.crm_id, mode: 'api', warning: outcome.warning)
    end

    # mode 'api' — из export!; 'manual' — сотрудник внёс объект руками и ввёл номер.
    def record_export!(card, crm_id:, mode:, actor: nil, warning: nil)
      digits = crm_id.to_s.strip
      result = card.with_lock do
        next deny('Номер карточки в CRM — только цифры.') unless digits.match?(/\A\d{1,12}\z/)

        if mode == 'manual'
          perms = Permissions.for(actor)
          allowed = perms.denial.nil? && (card.author_id == actor.id || perms.can?(:moderate))
          next deny(perms.denial || 'Отметить внесение в CRM может автор карточки или модератор.') unless allowed
          next deny("Карточка не ждёт ручного внесения (#{label(card)}).") unless card.kind_object? && card.status_approved?
        else
          next deny("Карточка не выгружается (#{label(card)}).") unless card.status_exporting?
        end

        transition!(card, to: 'exported', actor: actor, comment: warning)
        card.update!(crm_id: digits, exported_at: Time.current, export_error: warning)
        sync_lead_ref!(card)
        ok(card)
      end
      notifier.exported(card, warning: warning) if result.ok?
      result
    end

    def retry_export!(card, actor:)
      result = card.with_lock do
        next deny(moderator_denial(actor, 'Повторять выгрузку')) unless moderator?(actor)
        next deny('Повтор есть только у заявок — объект вносится в CRM вручную.') unless card.kind_lead?
        next deny("Повторять нечего (#{label(card)}).") unless card.status_export_failed? || card.export_stale?

        transition!(card, to: 'approved', actor: actor, comment: 'повтор выгрузки')
        card.update!(export_error: nil)
        ok(card)
      end
      ExportJob.perform_later(card.id) if result.ok?
      result
    end

    def can_edit?(card, actor, perms = Permissions.for(actor))
      return false if perms.denial
      return perms.can?(:moderate) if card.status_pending_review?
      return false unless CrmCard::AUTHOR_EDITABLE.include?(card.status)
      return true if perms.can?(:moderate)

      perms.can?("create_#{card.kind}") && (card.new_record? || card.author_id == actor.id)
    end

    def edit_denial(card, perms)
      return perms.denial if perms.denial
      return 'Карточка на модерации — править её сейчас может только модератор.' if card.status_pending_review?
      return "Карточка уже в статусе «#{label(card)}» — править нечего." unless CrmCard::AUTHOR_EDITABLE.include?(card.status)
      return "Твоей должности в CRM не выдано право заводить #{card.kind_lead? ? 'заявки' : 'объекты'}." unless perms.can?("create_#{card.kind}")

      "Карточку ведёт #{card.author.mention}."
    end

    private

    # take_over — ответственный по лиду перенимает черновик: он и станет
    # ответственным за заявку в CRM. Автор назначается внутри блокировки:
    # with_lock перечитывает строку и стёр бы несохранённое присваивание.
    def save_values(card, values, actor:, perms:, take_over: false)
      apply = lambda do
        card.author = actor if card.new_record? || (take_over && CrmCard::AUTHOR_EDITABLE.include?(card.status))
        next deny(edit_denial(card, perms)) unless can_edit?(card, actor, perms)

        allowed = Schema.for(card.kind).map(&:key)
        card.payload = card.payload.to_h.merge(values.to_h.stringify_keys.slice(*allowed)).compact
        refresh_check(card)
        card.save!
        ok(card)
      end
      card.persisted? ? card.with_lock(&apply) : apply.call
    end

    def refresh_check(card)
      card.check_errors = Checker.call(card)
      card.checked_at = Time.current
    end

    def transition!(card, to:, actor:, comment: nil)
      from = card.status
      card.update!(status: to)
      card.transitions.create!(from_status: from, to_status: to, actor: actor, comment: comment)
    end

    # Лид с сайта теперь «в CRM»: LeadAssignment#push_to_crm и SpamCallback
    # начинают работать с ним так же, как с пришедшим из CRM.
    def sync_lead_ref!(card)
      ref = card.lead_event&.lead_ref
      return unless ref&.has_attribute?(:crm_id) && ref.crm_id.blank?

      attrs = { crm_id: card.crm_id }
      attrs[:synced_to_crm_at] = Time.current if ref.has_attribute?(:synced_to_crm_at)
      ref.update_columns(attrs) # без колбэков: Inquiry на сохранении шлёт уведомления
    end

    def moderator?(actor)
      Permissions.for(actor).can?(:moderate)
    end

    def moderator_denial(actor, action)
      Permissions.for(actor).denial || "#{action} может только модератор."
    end

    def not_pending(card)
      "Карточка не на модерации (#{label(card)})."
    end

    def label(card)
      CrmCard::STATUS_LABELS[card.status]
    end

    def ok(card)
      Result.new(ok: true, card: card)
    end

    def deny(error)
      Result.new(ok: false, error: error)
    end

    def fail_export!(card, error:)
      message = error.to_s.truncate(500)
      result = card.with_lock do
        next deny('Карточка не выгружается.') unless card.status_exporting?

        transition!(card, to: 'export_failed', actor: nil, comment: message)
        card.update!(export_error: message)
        ok(card)
      end
      notifier.export_failed(card) if result.ok?
      result
    end

    def notifier
      @notifier ||= Notifier.new
    end

    def exporter
      @exporter ||= LeadExporter.new
    end
  end
end
```

- [ ] **Step 4: Джоб**

Создать `app/jobs/crm_cards/export_job.rb`:

```ruby
# frozen_string_literal: true

module CrmCards
  # Выгрузка одобренной заявки в CRM. Вся логика — в Workflow#export!.
  class ExportJob < ApplicationJob
    queue_as :default

    # Исключения не пробрасываются намеренно: ApplicationJob объявляет
    # retry_on StandardError, а Topnlab не идемпотентна — повторный
    # importClient после таймаута заводит вторую заявку. Карточка останется
    # «выгружается», через 15 минут модератор увидит кнопку повтора
    # с напоминанием сначала проверить CRM.
    def perform(card_id)
      card = CrmCard.find_by(id: card_id)
      return unless card

      Workflow.new.export!(card)
    rescue StandardError => e
      Rails.logger.error("[CrmCards::ExportJob] card=#{card_id} #{e.class}: #{e.message}")
    end
  end
end
```

- [ ] **Step 5: Прогнать — зелёные**

Run: `bin/rb --db bundle exec rspec spec/services/crm_cards/workflow_spec.rb spec/jobs/crm_cards/export_job_spec.rb`
Expected: `19 examples, 0 failures`.

Run: `bin/rb --db bundle exec rspec spec/services/crm_cards spec/models/crm_card_spec.rb`
Expected: весь стек A+B зелёный.

- [ ] **Step 6: Линт и коммит**

Run: `bin/rb bundle exec rubocop -a app/services/crm_cards/workflow.rb app/jobs/crm_cards/export_job.rb spec/services/crm_cards/workflow_spec.rb spec/jobs/crm_cards/export_job_spec.rb`

```bash
git add app/services/crm_cards/workflow.rb app/jobs/crm_cards/export_job.rb \
        spec/services/crm_cards/workflow_spec.rb spec/jobs/crm_cards/export_job_spec.rb
git commit -m "feat(crm_cards): переходы статусов, модерация и выгрузка без двойной заявки"
```

> **Конец стека B.** PR «конвейер» → CI → `/code-review` → правки.

---

## Стек C — Telegram: заявки

### Task 9: Мастер карточки заявки, кнопка под лидом, напоминание назначенному

**Files:**
- Create: `spec/support/wizard_dm_harness.rb`
- Create: `app/services/telegram/work_bot/wizard/crm_card_support.rb`
- Create: `app/services/telegram/work_bot/wizard/crm_lead_card_flow.rb`
- Modify: `app/services/telegram/work_bot/wizard/engine.rb` (`FLOWS`, `SEED_STEP`)
- Modify: `app/services/telegram/work_bot/lead_announcer.rb` (`#keyboard_for_card`, новый `#crm_row`)
- Modify: `app/services/telegram/work_bot/lead_assignment.rb` (`#notify_assignee`)
- Test: `spec/services/telegram/work_bot/wizard/crm_lead_card_flow_spec.rb`
- Test: `spec/services/telegram/work_bot/lead_announcer_crm_row_spec.rb`
- Test: `spec/services/telegram/work_bot/lead_assignment_crm_card_spec.rb`

**Interfaces:**
- Consumes: `Workflow#upsert_lead_card!`, `#can_edit?`, `#edit_denial` (Task 8); `CardView.render`, `.plain_value` (Task 6); `Schema`, `FieldValue` (Task 4); `Permissions` (Task 2); `Wizard::Flow`, `Wizard::Engine` — существующие.
- Produces: модуль `Wizard::CrmCardSupport` для мастеров карточек: `#permissions → Permissions::Result`, `#workflow → Workflow`, `#card → CrmCard|nil` (из `ctx['card']`), `#field_step(field, id: field.key, prompt: nil, clearable: false) → Flow::Step`, `#accept_field(field, value) → [значение, ошибка]`, `#result_view(result) → { text:, keyboard: }`, `#moderator_gate → String|nil`, константа `CLEAR = '__clear__'`.
- Produces: мастер `crm_lead` (старт `wiz:s:crm_lead:<lead_id>`, шаг-сид `lead`).
- Produces (спеки): shared context `'wizard DM harness'` — `dms`, `acks`, `tg_client`, `last_text`, `last_callbacks`, `press(label, user:, message: nil)`, `tap_callback(data, user:, chat_type: 'private')`, `say(text, user:)`.

- [ ] **Step 1: Общий контекст спек мастеров**

Создать `spec/support/wizard_dm_harness.rb`:

```ruby
# frozen_string_literal: true

# Гоняет мастера и кнопки так же, как сотрудник: нажатие берёт callback_data
# из клавиатуры сообщения и идёт через тот обработчик, который выбрал бы
# CallbacksRouter; текст — через Wizard::Engine#text. Так ловится расхождение
# между тем, что нарисовано, и тем, что разбирается.
RSpec.shared_context 'wizard DM harness' do
  let(:dms) { [] }
  let(:acks) { [] }
  let(:tg_client) do
    client = instance_double(Telegram::Client)
    allow(client).to receive(:send_message) do |text, **opts|
      dms << { text: text, keyboard: opts.dig(:reply_markup, :inline_keyboard) || [], chat_id: opts[:chat_id] }
      { 'message_id' => 1000 + dms.size }
    end
    allow(client).to receive_messages(edit_message_reply_markup: true, edit_message_text: { 'message_id' => 1 })
    allow(client).to receive(:answer_callback_query) { |_id, text: nil, show_alert: false| acks << [text, show_alert] }
    client
  end

  def last_text
    dms.last[:text]
  end

  def last_callbacks
    dms.last[:keyboard].flatten.map { |b| b[:callback_data] }
  end

  def press(label, user:, message: nil)
    message ||= dms.last
    button = message[:keyboard].flatten.find { |b| b[:text].include?(label) }
    raise "нет кнопки «#{label}» в: #{message[:keyboard].flatten.map { |b| b[:text] }}" unless button

    tap_callback(button[:callback_data], user: user)
  end

  def tap_callback(data, user:, chat_type: 'private')
    prefix, *args = data.split(':')
    handler = Telegram::WorkBot::CallbacksRouter::PREFIX_MAP.fetch(prefix).constantize
    callback_query = { 'id' => 'cb1', 'data' => data, 'from' => { 'id' => user.tg_user_id },
                       'message' => { 'message_id' => 1, 'chat' => { 'id' => user.tg_user_id, 'type' => chat_type } } }
    handler.new(callback_query: callback_query, tg_user: user, args: args, client: tg_client).call
  end

  def say(text, user:)
    Telegram::WorkBot::Wizard::Engine.new(tg_user: user, client: tg_client).text(text)
  end
end
```

- [ ] **Step 2: Спеки (красные)**

Создать `spec/services/telegram/work_bot/wizard/crm_lead_card_flow_spec.rb`:

```ruby
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Wizard::CrmLeadCardFlow do
  include_context 'wizard DM harness'

  before do
    stub_crm_positions
    allow(DispatcherDigestRefreshJob).to receive(:perform_async)
  end

  let!(:agent) { crm_staff(tg_user_id: 98_901, username: 'irina') }
  let!(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -1_003_779_115_845, anchor_message_id: 555,
                      assigned_to: agent, first_contact_at: 1.hour.ago,
                      metadata: { 'name' => 'Анна Смирнова', 'phone' => '+79101234567' })
  end

  it 'с кнопки под лидом: имя и телефон из заявки не спрашивает, остальное — по шагам' do
    tap_callback("wiz:s:crm_lead:#{lead.id}", user: agent, chat_type: 'supergroup')
    expect(acks.last.first).to include('личке')
    expect(last_text).to include('Что нужно клиенту?')

    press('Продажа', user: agent)
    expect(last_text).to include('Тип объекта?')

    press('Квартира', user: agent)
    expect(last_text).to include('Итог разговора с клиентом?')

    say('коротко', user: agent)
    expect(last_text).to include('Слишком коротко', 'Шаг не сброшен')

    say('Ищет двушку в Канищево до 6 млн, ипотека одобрена', user: agent)
    expect { press('Сохранить', user: agent) }.to change(CrmCard, :count).by(1)

    card = CrmCard.last
    expect(card).to have_attributes(author_id: agent.id, lead_event_id: lead.id, status: 'draft')
    expect(card.payload).to include('name' => 'Анна Смирнова', 'phone' => '79101234567',
                                    'action' => 'sale', 'object_type' => 'flat')
    expect(last_text).to include('✅ пройдена')
    expect(last_callbacks).to include("crm_card:#{card.id}:submit")
  end

  it 'по черновику спрашивает только незаполненное' do
    CrmCard.create!(kind: 'lead', author: agent, lead_event: lead,
                    payload: { 'name' => 'Анна', 'phone' => '79101234567', 'action' => 'rent', 'object_type' => 'room' })

    tap_callback("wiz:s:crm_lead:#{lead.id}", user: agent)

    expect(last_text).to include('Итог разговора с клиентом?')
  end

  it 'не ответственный по лиду получает отказ до первого вопроса' do
    petr = crm_staff(tg_user_id: 98_902, username: 'petr')

    tap_callback("wiz:s:crm_lead:#{lead.id}", user: petr)

    expect(last_text).to include('заполняет ответственный', '@irina')
    expect(petr.reload.pending_action).to be_nil
  end

  it 'должность без прав в CRM — отказ с причиной' do
    auditor = crm_staff(tg_user_id: 98_903, username: 'audit', position: '40')
    lead.update!(assigned_to: auditor)

    tap_callback("wiz:s:crm_lead:#{lead.id}", user: auditor)

    expect(last_text).to include('не выданы права')
  end

  it 'карточка уже на модерации — мастер не стартует' do
    card = CrmCard.create!(kind: 'lead', author: agent, lead_event: lead, status: 'pending_review')

    tap_callback("wiz:s:crm_lead:#{lead.id}", user: agent)

    expect(last_text).to include("Карточка ##{card.id}", 'На модерации')
  end
end
```

Создать `spec/services/telegram/work_bot/lead_announcer_crm_row_spec.rb`:

```ruby
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::LeadAnnouncer, 'кнопка карточки CRM' do
  let(:agent) { TelegramUser.create!(tg_user_id: 98_911, tg_username: 'irina', role: 'agent', status: 'active') }
  let(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1, assigned_to: agent)
  end

  def crm_buttons
    described_class.new(lead, client: instance_double(Telegram::Client)).keyboard_for_card[:inline_keyboard]
                   .flatten.select { |b| b[:text].include?('CRM') }
  end

  it 'лид без карточки — кнопка мастера заявки' do
    expect(crm_buttons.map { |b| b[:callback_data] }).to eq(["wiz:s:crm_lead:#{lead.id}"])
  end

  it 'возвращённая карточка — та же кнопка, но с призывом доработать' do
    CrmCard.create!(kind: 'lead', author: agent, lead_event: lead, status: 'needs_rework')

    expect(crm_buttons).to contain_exactly(a_hash_including(text: a_string_including('доработать'),
                                                            callback_data: "wiz:s:crm_lead:#{lead.id}"))
  end

  it 'карточка на модерации — статус и показ карточки в личке' do
    card = CrmCard.create!(kind: 'lead', author: agent, lead_event: lead, status: 'pending_review')

    expect(crm_buttons).to contain_exactly(a_hash_including(text: a_string_including('На модерации'),
                                                            callback_data: "crm_card:#{card.id}:view"))
  end

  it 'выгруженная — номер в CRM на кнопке' do
    CrmCard.create!(kind: 'lead', author: agent, lead_event: lead, status: 'exported', crm_id: '4455')

    expect(crm_buttons.map { |b| b[:text] }).to eq(['🟢 В CRM #4455'])
  end

  it 'закрытый лид с черновиком — мастер не предлагается' do
    CrmCard.create!(kind: 'lead', author: agent, lead_event: lead, status: 'draft')
    lead.update!(current_stage: 'closed_lost')

    expect(crm_buttons).to be_empty
  end

  it 'закрытый лид с выгруженной карточкой — статус остаётся виден' do
    CrmCard.create!(kind: 'lead', author: agent, lead_event: lead, status: 'exported', crm_id: '4455')
    lead.update!(current_stage: 'closed_won')

    expect(crm_buttons.map { |b| b[:text] }).to eq(['🟢 В CRM #4455'])
  end

  it 'лид, пришедший из CRM, кнопки не получает' do
    lead.lead_ref.update_columns(crm_id: '4455')

    expect(crm_buttons).to be_empty
  end

  it 'в группе — ни одного поля карточки, только статус' do
    CrmCard.create!(kind: 'lead', author: agent, lead_event: lead, status: 'pending_review',
                    payload: { 'phone' => '79101234567' })

    expect(described_class.new(lead, client: instance_double(Telegram::Client)).keyboard_for_card.to_s)
      .not_to include('9101234567')
  end
end
```

Создать `spec/services/telegram/work_bot/lead_assignment_crm_card_spec.rb`:

```ruby
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::LeadAssignment, 'напоминание о карточке CRM' do
  let(:tg_client) { instance_double(Telegram::Client, send_message: { 'message_id' => 1 }, edit_message_text: true) }
  let(:director) { TelegramUser.create!(tg_user_id: 98_921, tg_username: 'oksana', role: 'director', status: 'active') }
  let(:agent) do
    TelegramUser.create!(tg_user_id: 98_922, tg_username: 'irina', role: 'agent', status: 'active', dm_chat_id: 98_922)
  end
  let(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'new',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1, metadata: { 'name' => 'Анна' })
  end

  it 'назначенному приходит кнопка карточки CRM и объяснение, зачем она' do
    described_class.new(lead, assignee: agent, actor: director, client: tg_client).call

    expect(tg_client).to have_received(:send_message).with(
      a_string_including('карточку CRM'),
      hash_including(chat_id: agent.dm_chat_id,
                     reply_markup: { inline_keyboard: [[{ text: '📋 Карточка CRM',
                                                          callback_data: "wiz:s:crm_lead:#{lead.id}" }]] })
    )
  end

  it 'лиду, пришедшему из CRM, кнопка не нужна' do
    lead.lead_ref.update_columns(crm_id: '4455')

    described_class.new(lead, assignee: agent, actor: director, client: tg_client).call

    expect(tg_client).to have_received(:send_message).with(anything, hash_not_including(:reply_markup))
  end
end
```

- [ ] **Step 3: Прогнать — падают**

Run: `bin/rb --db bundle exec rspec spec/services/telegram/work_bot/wizard/crm_lead_card_flow_spec.rb spec/services/telegram/work_bot/lead_announcer_crm_row_spec.rb spec/services/telegram/work_bot/lead_assignment_crm_card_spec.rb`
Expected: FAIL — `KeyError`/`Неизвестный мастер` на `crm_lead`, кнопок CRM нет, `reply_markup` в личном сообщении нет.

- [ ] **Step 4: Общий модуль мастеров карточек**

Создать `app/services/telegram/work_bot/wizard/crm_card_support.rb`:

```ruby
# frozen_string_literal: true

module Telegram
  module WorkBot
    module Wizard
      # Общее для мастеров карточек CRM: шаг-вопрос на поле схемы, проверка
      # ввода через CrmCards::FieldValue, поиск карточки из callback_data.
      #
      # Права — только CrmCards::Permissions (из CRM), не роль в боте: поэтому
      # мастера карточек не объявляют manager_only, а отказывают в gate.
      module CrmCardSupport
        # Значение кнопки «Очистить» в мастере правки. Только кнопкой: текстом
        # его не ввести, поэтому в данные карточки он не протекает.
        CLEAR = '__clear__'

        def permissions
          @permissions ||= ::CrmCards::Permissions.for(tg_user)
        end

        def workflow
          @workflow ||= ::CrmCards::Workflow.new(notifier: ::CrmCards::Notifier.new(client: client))
        end

        def card
          return @card if defined?(@card)

          @card = ctx['card'].to_s.match?(/\A\d+\z/) ? ::CrmCard.find_by(id: ctx['card']) : nil
        end

        # Варианты — кнопками, остальное — текстом. clearable — только в правке:
        # в мастере заполнения «очистить» пустое поле бессмысленно.
        def field_step(field, id: field.key, prompt: nil, clearable: false)
          prompt ||= "#{field.label}?"
          if field.type == :choice
            Flow::Step.new(id: id, kind: :choice, per_row: 2, prompt: prompt, hint: field.hint, options: field.options)
          else
            quick = clearable ? [['🗑 Очистить', CLEAR]] : nil
            Flow::Step.new(id: id, kind: :input, prompt: prompt, hint: field.hint, quick: quick)
          end
        end

        # @return [Array(Object, String|nil)]
        def accept_field(field, value)
          return [nil, "Поле «#{field.label}» обязательное — очистить нельзя."] if value == CLEAR && field.required
          return [CLEAR, nil] if value == CLEAR

          ::CrmCards::FieldValue.normalize(field, value)
        end

        def result_view(result)
          return ::CrmCards::CardView.render(result.card, viewer: tg_user) if result.ok?

          { text: "⚠️ #{escape_html(result.error)}" }
        end

        def moderator_gate
          return '⚠️ Карточка не найдена.' unless card
          return "🚫 #{escape_html(permissions.denial)}" if permissions.denial
          return '🚫 Решение по карточке принимает модератор.' unless permissions.can?(:moderate)
          unless card.status_pending_review?
            return "ℹ️ Карточка ##{card.id} не на модерации — #{::CrmCard::STATUS_LABELS[card.status]}."
          end

          nil
        end
      end
    end
  end
end
```

- [ ] **Step 5: Мастер заявки**

Создать `app/services/telegram/work_bot/wizard/crm_lead_card_flow.rb`:

```ruby
# frozen_string_literal: true

module Telegram
  module WorkBot
    module Wizard
      # Мастер «Карточка заявки для CRM»: ответственный после разговора с
      # клиентом дозаполняет то, чего нет в лиде, и получает карточку с итогом
      # машинной проверки и кнопкой «На модерацию».
      #
      # Спрашивает только незаполненное обязательное: имя и телефон приходят
      # из лида, заполненное в черновике не повторяется. Необязательные поля —
      # через «Изменить поле». Последний шаг — подтверждение: мастер без
      # вопросов Engine не завершает, а для полного черновика так и было бы.
      class CrmLeadCardFlow < Flow
        include CrmCardSupport

        flow 'crm_lead', 'Карточка заявки для CRM'

        def steps
          ::CrmCards::Schema.for('lead').map { |field| field_step(field) } +
            [Flow::Step.new(id: 'confirm', kind: :confirm,
                            prompt: 'Сохранить карточку заявки? Дальше — машинная проверка.',
                            confirm_label: '💾 Сохранить и проверить')]
        end

        def skip?(step)
          field = ::CrmCards::Schema.field('lead', step.id)
          return false unless field
          return true unless field.required

          _, error = ::CrmCards::FieldValue.normalize(field, known_values[field.key])
          error.nil?
        end

        def gate
          return '⚠️ Карточку заявки открывают кнопкой «📋 Карточка CRM» под лидом.' unless lead
          return "🚫 #{escape_html(permissions.denial)}" if permissions.denial
          return '🚫 Твоей должности в CRM не выдано право заводить заявки.' unless permissions.can?(:create_lead)

          unless lead.assigned_to_id == tg_user.id || permissions.can?(:moderate)
            responsible = lead.assigned_to&.mention || 'пока никто не назначен'
            return "🚫 Карточку заполняет ответственный по лиду: #{escape_html(responsible)}."
          end
          if existing && !::CrmCard::AUTHOR_EDITABLE.include?(existing.status)
            return "ℹ️ Карточка ##{existing.id} по этому лиду — #{::CrmCard::STATUS_LABELS[existing.status]}. " \
                   'Открой её через /cards.'
          end

          nil
        end

        def accept(step, value, manual: false)
          field = ::CrmCards::Schema.field('lead', step.id)
          field ? accept_field(field, value) : [value, nil]
        end

        def finish
          return { text: '⚠️ Лид не найден — карточка не сохранена.' } unless lead

          answers = ::CrmCards::Schema.for('lead').to_h { |f| [f.key, ctx[f.key]] }.compact
          result_view(workflow.upsert_lead_card!(lead: lead, actor: tg_user, values: known_values.merge(answers)))
        end

        private

        def lead
          return @lead if defined?(@lead)

          @lead = ctx['lead'].to_s.match?(/\A\d+\z/) ? ::LeadEvent.find_by(id: ctx['lead']) : nil
        end

        def existing
          return @existing if defined?(@existing)

          @existing = lead && ::CrmCard.kind_lead.find_by(lead_event_id: lead.id)
        end

        # Известное заранее: черновик поверх данных, пришедших с лидом.
        def known_values
          @known_values ||= prefill.merge(existing&.payload.to_h)
        end

        def prefill
          meta = lead&.metadata.to_h
          values = {}
          name = meta['name'].to_s.strip
          values['name'] = name if name.present? && name != 'Без имени'
          phone, error = ::CrmCards::FieldValue.phone(meta['phone'].to_s)
          values['phone'] = phone unless error
          external_id = lead&.property&.external_id.to_s
          values['realty_id'] = external_id.to_i if external_id.match?(/\A\d+\z/)
          values
        end
      end
    end
  end
end
```

- [ ] **Step 6: Регистрация мастера**

В `app/services/telegram/work_bot/wizard/engine.rb` заменить:

```ruby
        FLOWS = {
          'task' => 'Telegram::WorkBot::Wizard::TaskFlow',
          'close' => 'Telegram::WorkBot::Wizard::CloseFlow',
          'reopen' => 'Telegram::WorkBot::Wizard::ReopenFlow'
        }.freeze

        # Какой шаг получает id, пришедший с кнопкой на карточке.
        SEED_STEP = { 'task' => 'lead', 'close' => 'lead', 'reopen' => 'task' }.freeze
```

на:

```ruby
        FLOWS = {
          'task' => 'Telegram::WorkBot::Wizard::TaskFlow',
          'close' => 'Telegram::WorkBot::Wizard::CloseFlow',
          'reopen' => 'Telegram::WorkBot::Wizard::ReopenFlow',
          # Карточки CRM через модерацию (docs/superpowers/specs/2026-09-14-crm-card-moderation-design.md).
          'crm_lead' => 'Telegram::WorkBot::Wizard::CrmLeadCardFlow'
        }.freeze

        # Какой шаг получает id, пришедший с кнопкой на карточке.
        SEED_STEP = { 'task' => 'lead', 'close' => 'lead', 'reopen' => 'task', 'crm_lead' => 'lead' }.freeze
```

- [ ] **Step 7: Кнопка под карточкой лида**

В `app/services/telegram/work_bot/lead_announcer.rb` в `#keyboard_for_card` заменить:

```ruby
        rows << work_row if @lead.open?
        { inline_keyboard: rows }
```

на:

```ruby
        rows << work_row if @lead.open?
        crm = crm_row
        rows << crm if crm
        { inline_keyboard: rows }
```

И добавить приватный метод сразу после `#work_row`:

```ruby
      # Карточка для CRM. Лид с сайта или из Telegram попадает в CRM только
      # через модерацию (CrmCards::Workflow). В группе — только кнопка и
      # статус: поля с телефоном клиента показываются лишь в личке.
      # Лид, пришедший из CRM (crm_id уже есть), кнопки не получает. На
      # закрытом лиде заполнять нечего — мастер не предлагаем (как «Задачу»
      # и «Закрыть лид»), но статус уже отправленной карточки остаётся виден.
      def crm_row
        card = ::CrmCard.kind_lead.find_by(lead_event_id: @lead.id)
        if card.nil? || ::CrmCard::AUTHOR_EDITABLE.include?(card.status)
          return nil if @lead.closed? || @lead.lead_ref.try(:crm_id).present?

          label = card&.status_needs_rework? ? '↩️ Карточка CRM: доработать' : '📋 Карточка CRM'
          return [{ text: label, callback_data: "wiz:s:crm_lead:#{@lead.id}" }]
        end

        label = card.status_exported? ? "🟢 В CRM ##{card.crm_id}" : "#{::CrmCard::STATUS_LABELS[card.status]} · CRM"
        [{ text: label, callback_data: "crm_card:#{card.id}:view" }]
      end
```

- [ ] **Step 8: Напоминание назначенному**

В `app/services/telegram/work_bot/lead_assignment.rb` в `#notify_assignee` заменить:

```ruby
        link = @lead.anchor_url
        text += "\n\n<a href=\"#{link}\">Открыть карточку</a>" if link.present?

        @client.send_message(text, chat_id: chat_id, parse_mode: 'HTML')
```

на:

```ruby
        link = @lead.anchor_url
        text += "\n\n<a href=\"#{link}\">Открыть карточку</a>" if link.present?

        opts = { chat_id: chat_id, parse_mode: 'HTML' }
        # Лид с сайта в CRM сам не попадёт: после разговора с клиентом
        # ответственный заполняет карточку, её проверяет модератор.
        if @lead.lead_ref.try(:crm_id).blank?
          text += "\n\nПосле разговора с клиентом заполни карточку CRM — без модерации заявка в CRM не попадёт."
          opts[:reply_markup] = { inline_keyboard: [[{ text: '📋 Карточка CRM', callback_data: "wiz:s:crm_lead:#{@lead.id}" }]] }
        end

        @client.send_message(text, **opts)
```

- [ ] **Step 9: Прогнать — зелёные, соседи не сломаны**

Run: `bin/rb --db bundle exec rspec spec/services/telegram/work_bot/wizard/crm_lead_card_flow_spec.rb spec/services/telegram/work_bot/lead_announcer_crm_row_spec.rb spec/services/telegram/work_bot/lead_assignment_crm_card_spec.rb`
Expected: `15 examples, 0 failures`.

Run: `bin/rb --db bundle exec rspec spec/services/telegram/work_bot spec/services/lead`
Expected: 0 failures. Две спеки касаются клавиатуры карточки лида и должны остаться зелёными без правок: `wizard/engine_spec.rb` («на закрытом лиде нет кнопок `wiz:`» — поэтому `crm_row` молчит на закрытом лиде без отправленной карточки) и `segment_keyboard_spec.rb` (проверяет наличие кнопок, а не всю клавиатуру). Спеки `/assign` проверяют текст и `chat_id` через `hash_including`, лишний `reply_markup` в личном сообщении их не ломает.

- [ ] **Step 10: Линт и коммит**

Run: `bin/rb bundle exec rubocop -a app/services/telegram/work_bot/wizard/crm_card_support.rb app/services/telegram/work_bot/wizard/crm_lead_card_flow.rb app/services/telegram/work_bot/wizard/engine.rb app/services/telegram/work_bot/lead_announcer.rb app/services/telegram/work_bot/lead_assignment.rb spec/support/wizard_dm_harness.rb spec/services/telegram/work_bot/wizard/crm_lead_card_flow_spec.rb spec/services/telegram/work_bot/lead_announcer_crm_row_spec.rb spec/services/telegram/work_bot/lead_assignment_crm_card_spec.rb`

```bash
git add spec/support/wizard_dm_harness.rb app/services/telegram/work_bot/wizard/crm_card_support.rb \
        app/services/telegram/work_bot/wizard/crm_lead_card_flow.rb app/services/telegram/work_bot/wizard/engine.rb \
        app/services/telegram/work_bot/lead_announcer.rb app/services/telegram/work_bot/lead_assignment.rb \
        spec/services/telegram/work_bot/wizard/crm_lead_card_flow_spec.rb \
        spec/services/telegram/work_bot/lead_announcer_crm_row_spec.rb \
        spec/services/telegram/work_bot/lead_assignment_crm_card_spec.rb
git commit -m "feat(work_bot): карточка заявки CRM — мастер, кнопка под лидом, напоминание назначенному"
```

### Task 10: Мастер «Изменить поле»

**Files:**
- Create: `app/services/telegram/work_bot/wizard/crm_card_edit_flow.rb`
- Modify: `app/services/telegram/work_bot/wizard/engine.rb` (`FLOWS`, `SEED_STEP`)
- Test: `spec/services/telegram/work_bot/wizard/crm_card_edit_flow_spec.rb`

**Interfaces:**
- Consumes: `CrmCardSupport` (Task 9), `Workflow#update_fields!`, `#can_edit?`, `#edit_denial` (Task 8), `CardView.plain_value` (Task 6).
- Produces: мастер `crm_edit` (старт `wiz:s:crm_edit:<card_id>`, шаг-сид `card`). Шаги: `field` → `value` → `confirm`. Используется автором (черновик, возврат) и модератором (на модерации).

- [ ] **Step 1: Спека (красная)**

Создать `spec/services/telegram/work_bot/wizard/crm_card_edit_flow_spec.rb`:

```ruby
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Wizard::CrmCardEditFlow do
  include_context 'wizard DM harness'

  before do
    stub_crm_positions
    allow(DispatcherDigestRefreshJob).to receive(:perform_async)
  end

  let!(:agent)    { crm_staff(tg_user_id: 98_931, username: 'irina') }
  let!(:director) { crm_staff(tg_user_id: 98_932, username: 'oksana', position: '89884', role: 'director') }
  let(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1, assigned_to: agent,
                      first_contact_at: 1.hour.ago)
  end
  let!(:card) do
    CrmCards::Workflow.new(notifier: instance_double(CrmCards::Notifier)).upsert_lead_card!(
      lead: lead, actor: agent,
      values: { 'name' => 'Анна', 'phone' => '79101234567', 'action' => 'sale', 'object_type' => 'flat',
                'comment' => 'Ищет двушку до 6 млн, ипотека одобрена' }
    ).card
  end

  it 'автор меняет телефон: неверный ввод не сбрасывает шаг, верный нормализуется и перепроверяется' do
    tap_callback("wiz:s:crm_edit:#{card.id}", user: agent)
    press('Телефон', user: agent)

    say('12345', user: agent)
    expect(last_text).to include('11 цифр', 'Шаг не сброшен')

    say('8 (920) 555-44-33', user: agent)
    expect(last_text).to include('Сохранить «Телефон: +7 920 555-44-33»?')
    press('Сохранить', user: agent)

    expect(card.reload.payload['phone']).to eq('79205554433')
    expect(last_text).to include('Телефон: +7 920 555-44-33', '✅ пройдена')
  end

  it 'необязательное поле можно очистить кнопкой' do
    card.update!(payload: card.payload.merge('realty_id' => 12_345))

    tap_callback("wiz:s:crm_edit:#{card.id}", user: agent)
    press('ID объекта', user: agent)
    press('Очистить', user: agent)
    press('Сохранить', user: agent)

    expect(card.reload.payload).not_to have_key('realty_id')
  end

  it 'у обязательного поля кнопки «Очистить» нет' do
    tap_callback("wiz:s:crm_edit:#{card.id}", user: agent)
    press('Имя клиента', user: agent)

    expect(dms.last[:keyboard].flatten.map { |b| b[:text] }).not_to include('🗑 Очистить')
  end

  it 'на модерации автор править не может, модератор — может' do
    card.update!(status: 'pending_review')

    tap_callback("wiz:s:crm_edit:#{card.id}", user: agent)
    expect(last_text).to include('только модератор')

    tap_callback("wiz:s:crm_edit:#{card.id}", user: director)
    expect(last_text).to include("Какое поле карточки ##{card.id} изменить?")
  end
end
```

- [ ] **Step 2: Прогнать — падает**

Run: `bin/rb --db bundle exec rspec spec/services/telegram/work_bot/wizard/crm_card_edit_flow_spec.rb`
Expected: FAIL — «Неизвестный мастер» (`crm_edit` не зарегистрирован).

- [ ] **Step 3: Мастер**

Создать `app/services/telegram/work_bot/wizard/crm_card_edit_flow.rb`:

```ruby
# frozen_string_literal: true

module Telegram
  module WorkBot
    module Wizard
      # Мастер «Изменить поле карточки CRM»: поле → новое значение →
      # подтверждение. Один мастер на доработку автором и на правку
      # модератором во время модерации — кто может править, решает Workflow.
      class CrmCardEditFlow < Flow
        include CrmCardSupport

        flow 'crm_edit', 'Изменить поле карточки CRM'

        def steps
          return [] unless card

          list = [Flow::Step.new(id: 'field', kind: :choice, per_row: 1,
                                 prompt: "Какое поле карточки ##{card.id} изменить?",
                                 options: schema.map { |f| [field_button(f), f.key] })]
          return list unless chosen

          list << field_step(chosen, id: 'value', prompt: "#{chosen.label} — новое значение?",
                                     clearable: !chosen.required)
          list << Flow::Step.new(id: 'confirm', kind: :confirm, prompt: confirm_prompt, confirm_label: '💾 Сохранить')
        end

        def gate
          return '⚠️ Карточка не найдена.' unless card
          return nil if workflow.can_edit?(card, tg_user, permissions)

          "🚫 #{escape_html(workflow.edit_denial(card, permissions))}"
        end

        def accept(step, value, manual: false)
          case step.id
          when 'field' then schema.any? { |f| f.key == value } ? [value, nil] : [nil, 'Такого поля нет — выбери кнопкой.']
          when 'value' then accept_field(chosen, value)
          else [value, nil]
          end
        end

        def finish
          return { text: '⚠️ Карточка не найдена — ничего не изменено.' } unless card && chosen

          value = ctx['value'] == CLEAR ? nil : ctx['value']
          result_view(workflow.update_fields!(card, { chosen.key => value }, actor: tg_user))
        end

        private

        def schema
          ::CrmCards::Schema.for(card.kind)
        end

        def chosen
          return nil unless card && ctx['field'].present?

          ::CrmCards::Schema.field(card.kind, ctx['field'])
        end

        # Текст кнопки — не HTML, экранировать не нужно.
        def field_button(field)
          value = card.payload[field.key]
          shown = value.nil? ? '—' : ::CrmCards::CardView.plain_value(field, value)
          "#{field.label}: #{shown}".truncate(60)
        end

        def confirm_prompt
          return '' unless chosen && ctx.key?('value')

          shown = ctx['value'] == CLEAR ? 'очистить' : ::CrmCards::CardView.plain_value(chosen, ctx['value'])
          "Сохранить «#{escape_html(chosen.label)}: #{escape_html(shown)}»?"
        end
      end
    end
  end
end
```

- [ ] **Step 4: Регистрация**

В `app/services/telegram/work_bot/wizard/engine.rb` заменить:

```ruby
          'crm_lead' => 'Telegram::WorkBot::Wizard::CrmLeadCardFlow'
        }.freeze

        # Какой шаг получает id, пришедший с кнопкой на карточке.
        SEED_STEP = { 'task' => 'lead', 'close' => 'lead', 'reopen' => 'task', 'crm_lead' => 'lead' }.freeze
```

на:

```ruby
          'crm_lead' => 'Telegram::WorkBot::Wizard::CrmLeadCardFlow',
          'crm_edit' => 'Telegram::WorkBot::Wizard::CrmCardEditFlow'
        }.freeze

        # Какой шаг получает id, пришедший с кнопкой на карточке.
        SEED_STEP = { 'task' => 'lead', 'close' => 'lead', 'reopen' => 'task',
                      'crm_lead' => 'lead', 'crm_edit' => 'card' }.freeze
```

- [ ] **Step 5: Прогнать — зелёная**

Run: `bin/rb --db bundle exec rspec spec/services/telegram/work_bot/wizard/crm_card_edit_flow_spec.rb`
Expected: `4 examples, 0 failures`.

- [ ] **Step 6: Линт и коммит**

Run: `bin/rb bundle exec rubocop -a app/services/telegram/work_bot/wizard/crm_card_edit_flow.rb app/services/telegram/work_bot/wizard/engine.rb spec/services/telegram/work_bot/wizard/crm_card_edit_flow_spec.rb`

```bash
git add app/services/telegram/work_bot/wizard/crm_card_edit_flow.rb app/services/telegram/work_bot/wizard/engine.rb \
        spec/services/telegram/work_bot/wizard/crm_card_edit_flow_spec.rb
git commit -m "feat(work_bot): мастер правки поля карточки CRM"
```

### Task 11: Модерация в Telegram — отправка, возврат, одобрение, повтор

**Files:**
- Create: `app/services/telegram/work_bot/callbacks/crm_card_callback.rb`
- Create: `app/services/telegram/work_bot/wizard/crm_card_rework_flow.rb`
- Create: `app/services/telegram/work_bot/wizard/crm_card_approve_flow.rb`
- Modify: `app/services/telegram/work_bot/callbacks_router.rb` (`PREFIX_MAP`)
- Modify: `app/services/telegram/work_bot/wizard/engine.rb` (`FLOWS`, `SEED_STEP`)
- Test: `spec/services/telegram/work_bot/crm_card_moderation_spec.rb`

**Interfaces:**
- Consumes: `Workflow#submit!`, `#return_for_rework!`, `#approve!`, `#retry_export!` (Task 8); `CardView.render` (Task 6); `CrmCardSupport#moderator_gate`, `#workflow` (Task 9).
- Produces: `crm_card:<card_id>:view|submit|retry`; мастера `crm_rework` и `crm_approve` (шаг-сид `card`).

- [ ] **Step 1: Спека (красная)**

Создать `spec/services/telegram/work_bot/crm_card_moderation_spec.rb`:

```ruby
# frozen_string_literal: true

require 'rails_helper'

# Путь карточки заявки глазами людей: автор → модератор → автор → модератор.
# Все нажатия — настоящими callback_data из присланных сообщений.
RSpec.describe 'модерация карточки CRM в Telegram' do
  include_context 'wizard DM harness'

  before do
    stub_crm_positions
    allow(DispatcherDigestRefreshJob).to receive(:perform_async)
  end

  let!(:agent)    { crm_staff(tg_user_id: 98_941, username: 'irina') }
  let!(:director) { crm_staff(tg_user_id: 98_942, username: 'oksana', position: '89884', role: 'director') }
  let(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1, anchor_message_id: 555,
                      assigned_to: agent, first_contact_at: 1.hour.ago)
  end
  let!(:card) do
    CrmCards::Workflow.new(notifier: instance_double(CrmCards::Notifier)).upsert_lead_card!(
      lead: lead, actor: agent,
      values: { 'name' => 'Анна', 'phone' => '79101234567', 'action' => 'sale', 'object_type' => 'flat',
                'comment' => 'Ищет двушку до 6 млн, ипотека одобрена' }
    ).card
  end

  def last_dm_to(user)
    dms.reverse.find { |m| m[:chat_id] == user.dm_chat_id }
  end

  it 'на модерацию → возврат с комментарием → повторная отправка → одобрение → выгрузка в очереди' do
    tap_callback("crm_card:#{card.id}:submit", user: agent)
    expect(card.reload).to be_status_pending_review
    expect(acks.last.first).to include('Отправлено на модерацию')
    expect(last_dm_to(director)[:text]).to include('На модерацию', '@irina')

    press('На доработку', user: director, message: last_dm_to(director))
    expect(last_text).to include("Что доработать в карточке ##{card.id}?")
    say('Уточни бюджет и срок покупки', user: director)
    press('Вернуть', user: director)
    expect(card.reload).to be_status_needs_rework
    expect(last_dm_to(agent)[:text]).to include('вернулась на доработку', 'Уточни бюджет и срок покупки')

    tap_callback("crm_card:#{card.id}:submit", user: agent)
    expect(card.reload).to be_status_pending_review

    tap_callback("wiz:s:crm_approve:#{card.id}", user: director)
    expect(last_text).to include('Ответственным в CRM станет @irina')
    expect { press('Одобрить', user: director) }.to have_enqueued_job(CrmCards::ExportJob).with(card.id)
    expect(card.reload).to be_status_approved
  end

  it 'повторное нажатие «На модерацию» не создаёт второго перехода' do
    tap_callback("crm_card:#{card.id}:submit", user: agent)
    tap_callback("crm_card:#{card.id}:submit", user: agent)

    expect(acks.last.first).to include('на модерации')
    expect(acks.last.last).to be(true)
    expect(card.transitions.count).to eq(1)
  end

  it 'агент не может запустить одобрение даже прямым callback_data' do
    card.update!(status: 'pending_review')

    tap_callback("wiz:s:crm_approve:#{card.id}", user: agent)

    expect(last_text).to include('принимает модератор')
    expect(card.reload).to be_status_pending_review
  end

  it 'кнопка статуса под лидом: карточку — в личку; посторонним — отказ' do
    tap_callback("crm_card:#{card.id}:view", user: agent, chat_type: 'supergroup')
    expect(dms.last[:chat_id]).to eq(agent.dm_chat_id)
    expect(acks.last.first).to include('личке')

    petr = crm_staff(tg_user_id: 98_943, username: 'petr')
    tap_callback("crm_card:#{card.id}:view", user: petr, chat_type: 'supergroup')
    expect(acks.last).to eq(['🚫 Карточку видят автор, ответственный по лиду и модераторы.', true])
  end

  it 'повтор выгрузки — кнопкой модератора' do
    card.update!(status: 'export_failed', export_error: 'HTTP 502')

    expect { tap_callback("crm_card:#{card.id}:retry", user: director) }
      .to have_enqueued_job(CrmCards::ExportJob).with(card.id)
    expect(card.reload).to be_status_approved
  end
end
```

- [ ] **Step 2: Прогнать — падает**

Run: `bin/rb --db bundle exec rspec spec/services/telegram/work_bot/crm_card_moderation_spec.rb`
Expected: FAIL — `KeyError: key not found: "crm_card"` в `PREFIX_MAP.fetch`.

- [ ] **Step 3: Кнопки карточки**

Создать `app/services/telegram/work_bot/callbacks/crm_card_callback.rb`:

```ruby
# frozen_string_literal: true

module Telegram
  module WorkBot
    module Callbacks
      # Кнопки карточки CRM вне мастеров.
      # callback_data: "crm_card:<card_id>:<view|submit|retry>".
      #
      # Решения модератора с последствиями (одобрить, вернуть) идут мастерами
      # с подтверждением; здесь — действия без выбора и ввода. Права
      # перепроверяет Workflow: устаревшая кнопка в старом сообщении
      # получает отказ с объяснением, а не второе действие.
      class CrmCardCallback < Base
        def handle
          card = ::CrmCard.find_by(id: @args[0].to_s[/\A\d+\z/])
          return ack('⚠️ Карточка не найдена', alert: true) unless card

          case @args[1]
          when 'view'   then show(card)
          when 'submit' then apply(workflow.submit!(card, actor: tg_user), '📤 Отправлено на модерацию')
          when 'retry'  then apply(workflow.retry_export!(card, actor: tg_user), '🔁 Выгрузка запущена снова')
          else ack('⚠️ Неизвестное действие', alert: true)
          end
        end

        private

        def workflow
          @workflow ||= ::CrmCards::Workflow.new(notifier: ::CrmCards::Notifier.new(client: client))
        end

        # В карточке телефон клиента — показываем только в личке, даже если
        # кнопку нажали под лидом в группе.
        def show(card)
          return ack('🚫 Карточку видят автор, ответственный по лиду и модераторы.', alert: true) unless viewer?(card)
          unless send_dm(::CrmCards::CardView.render(card, viewer: tg_user))
            return ack('Не могу написать в личку. Открой чат с ботом, нажми «Start» и нажми кнопку ещё раз.', alert: true)
          end

          ack(private_chat? ? nil : '↘︎ Карточка — в личке с ботом')
        end

        # В личке перерисовываем нажатое сообщение — старые кнопки под ним
        # исчезают. Из группы — новое сообщение в личку.
        def apply(result, success_text)
          return ack("⚠️ #{result.error}".truncate(190), alert: true) unless result.ok?

          view = ::CrmCards::CardView.render(result.card.reload, viewer: tg_user)
          private_chat? ? redraw(view) : send_dm(view)
          ack(success_text)
        end

        def viewer?(card)
          card.author_id == tg_user.id ||
            card.lead_event&.assigned_to_id == tg_user.id ||
            ::CrmCards::Permissions.for(tg_user).can?(:moderate)
        end

        def redraw(view)
          msg = callback_query['message'] || {}
          client.edit_message_text(view[:text], chat_id: msg.dig('chat', 'id'), message_id: msg['message_id'],
                                                reply_markup: { inline_keyboard: view[:keyboard] }, parse_mode: 'HTML')
        rescue Telegram::Client::Error => e
          Rails.logger.info("[CrmCardCallback#redraw] #{e.message} — шлю новым сообщением")
          send_dm(view)
        end

        def send_dm(view)
          client.send_message(view[:text], chat_id: tg_user.dm_chat_id || tg_user.tg_user_id, parse_mode: 'HTML',
                                           reply_markup: { inline_keyboard: view[:keyboard] })
          true
        rescue Telegram::Client::Error => e
          Rails.logger.warn("[CrmCardCallback] DM to #{tg_user.mention} failed: #{e.message}")
          false
        end

        def private_chat?
          callback_query.dig('message', 'chat', 'type') == 'private'
        end
      end
    end
  end
end
```

- [ ] **Step 4: Мастера модератора**

Создать `app/services/telegram/work_bot/wizard/crm_card_rework_flow.rb`:

```ruby
# frozen_string_literal: true

module Telegram
  module WorkBot
    module Wizard
      # Модератор возвращает карточку на доработку. Комментарий обязателен:
      # возврат без объяснения автор может только угадывать.
      class CrmCardReworkFlow < Flow
        include CrmCardSupport

        flow 'crm_rework', 'Вернуть карточку CRM на доработку'

        COMMENT_MIN = 5
        COMMENT_MAX = 500

        def steps
          [
            Flow::Step.new(id: 'comment', kind: :input, prompt: "Что доработать в карточке ##{ctx['card']}?",
                           hint: 'Автор увидит это дословно. Конкретно: «нет бюджета», «телефон не отвечает».'),
            Flow::Step.new(id: 'confirm', kind: :confirm, prompt: 'Вернуть карточку автору на доработку?',
                           confirm_label: '↩️ Вернуть')
          ]
        end

        def gate
          moderator_gate
        end

        def accept(step, value, manual: false)
          return [value, nil] unless step.id == 'comment'

          text = value.to_s.strip
          return [nil, "Слишком коротко: нужно от #{COMMENT_MIN} символов."] if text.length < COMMENT_MIN
          return [nil, "Слишком длинно: #{text.length} симв., влезает #{COMMENT_MAX}."] if text.length > COMMENT_MAX

          [text, nil]
        end

        def finish
          return { text: '⚠️ Карточка не найдена — ничего не возвращено.' } unless card

          result = workflow.return_for_rework!(card, actor: tg_user, comment: ctx['comment'])
          return { text: "⚠️ #{escape_html(result.error)}" } unless result.ok?

          { text: "↩️ Карточка ##{card.id} возвращена: #{escape_html(card.author.mention)} получил комментарий." }
        end
      end
    end
  end
end
```

Создать `app/services/telegram/work_bot/wizard/crm_card_approve_flow.rb`:

```ruby
# frozen_string_literal: true

module Telegram
  module WorkBot
    module Wizard
      # Модератор одобряет карточку. Подтверждение — отдельным шагом: для
      # заявки это запись в боевую CRM, которую мы не умеем отменять.
      class CrmCardApproveFlow < Flow
        include CrmCardSupport

        flow 'crm_approve', 'Одобрить карточку CRM'

        def steps
          [Flow::Step.new(id: 'confirm', kind: :confirm, prompt: confirm_prompt,
                          confirm_label: card&.kind_lead? ? '✅ Одобрить и выгрузить' : '✅ Одобрить')]
        end

        def gate
          moderator_gate
        end

        def finish
          return { text: '⚠️ Карточка не найдена — ничего не одобрено.' } unless card

          result = workflow.approve!(card, actor: tg_user)
          return { text: "⚠️ #{escape_html(result.error)}" } unless result.ok?

          done = if card.kind_lead?
                   'выгрузка в CRM запущена, итог придёт сообщением'
                 else
                   "объект внесёт в CRM вручную #{escape_html(card.author.mention)}"
                 end
          { text: "✅ Карточка ##{card.id} одобрена: #{done}." }
        end

        private

        def confirm_prompt
          return '' unless card
          return "Одобрить объект ##{card.id}?\nВ CRM его внесёт вручную #{escape_html(card.author.mention)}." if card.kind_object?

          "Одобрить заявку ##{card.id} и выгрузить в CRM?\nОтветственным в CRM станет #{escape_html(card.author.mention)}."
        end
      end
    end
  end
end
```

- [ ] **Step 5: Регистрация**

В `app/services/telegram/work_bot/callbacks_router.rb` заменить:

```ruby
        'wiz' => 'Telegram::WorkBot::Callbacks::WizardCallback'
      }.freeze
```

на:

```ruby
        'wiz' => 'Telegram::WorkBot::Callbacks::WizardCallback',
        # Карточка CRM: показать в личке, отправить на модерацию, повторить выгрузку.
        'crm_card' => 'Telegram::WorkBot::Callbacks::CrmCardCallback'
      }.freeze
```

В `app/services/telegram/work_bot/wizard/engine.rb` заменить:

```ruby
          'crm_edit' => 'Telegram::WorkBot::Wizard::CrmCardEditFlow'
        }.freeze

        # Какой шаг получает id, пришедший с кнопкой на карточке.
        SEED_STEP = { 'task' => 'lead', 'close' => 'lead', 'reopen' => 'task',
                      'crm_lead' => 'lead', 'crm_edit' => 'card' }.freeze
```

на:

```ruby
          'crm_edit' => 'Telegram::WorkBot::Wizard::CrmCardEditFlow',
          'crm_rework' => 'Telegram::WorkBot::Wizard::CrmCardReworkFlow',
          'crm_approve' => 'Telegram::WorkBot::Wizard::CrmCardApproveFlow'
        }.freeze

        # Какой шаг получает id, пришедший с кнопкой на карточке.
        SEED_STEP = { 'task' => 'lead', 'close' => 'lead', 'reopen' => 'task',
                      'crm_lead' => 'lead', 'crm_edit' => 'card', 'crm_rework' => 'card',
                      'crm_approve' => 'card' }.freeze
```

- [ ] **Step 6: Прогнать — зелёная**

Run: `bin/rb --db bundle exec rspec spec/services/telegram/work_bot/crm_card_moderation_spec.rb`
Expected: `5 examples, 0 failures`.

- [ ] **Step 7: Линт и коммит**

Run: `bin/rb bundle exec rubocop -a app/services/telegram/work_bot/callbacks/crm_card_callback.rb app/services/telegram/work_bot/wizard/crm_card_rework_flow.rb app/services/telegram/work_bot/wizard/crm_card_approve_flow.rb app/services/telegram/work_bot/callbacks_router.rb app/services/telegram/work_bot/wizard/engine.rb spec/services/telegram/work_bot/crm_card_moderation_spec.rb`

```bash
git add app/services/telegram/work_bot/callbacks/crm_card_callback.rb \
        app/services/telegram/work_bot/wizard/crm_card_rework_flow.rb \
        app/services/telegram/work_bot/wizard/crm_card_approve_flow.rb \
        app/services/telegram/work_bot/callbacks_router.rb app/services/telegram/work_bot/wizard/engine.rb \
        spec/services/telegram/work_bot/crm_card_moderation_spec.rb
git commit -m "feat(work_bot): модерация карточки CRM — отправка, возврат, одобрение, повтор выгрузки"
```

### Task 12: `/cards` — очередь в личке

**Files:**
- Create: `app/services/telegram/work_bot/commands/cards.rb`
- Modify: `app/services/telegram/work_bot/router.rb` (`COMMANDS`)
- Modify: `app/services/telegram/work_bot/commands/help.rb` (`ENTRIES`)
- Modify: `config/telegram_bot_commands.yml`
- Test: `spec/services/telegram/work_bot/commands/cards_spec.rb`

**Interfaces:**
- Consumes: `Permissions` (Task 2), `CrmCard` (Task 1), `crm_card:<id>:view` (Task 11).
- Produces: команда `/cards` (tier `staff`, только личка).

- [ ] **Step 1: Спека (красная)**

Создать `spec/services/telegram/work_bot/commands/cards_spec.rb`:

```ruby
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Commands::Cards do
  let(:sent) { [] }
  let(:tg_client) do
    client = instance_double(Telegram::Client)
    allow(client).to receive(:send_message) do |text, **opts|
      sent << { text: text, keyboard: opts.dig(:reply_markup, :inline_keyboard) || [] }
      { 'message_id' => 1 }
    end
    client
  end

  before { stub_crm_positions }

  let!(:agent)    { crm_staff(tg_user_id: 98_951, username: 'irina') }
  let!(:director) { crm_staff(tg_user_id: 98_952, username: 'oksana', position: '89884', role: 'director') }
  let!(:draft)    { CrmCard.create!(kind: 'lead', author: agent, payload: { 'name' => 'Анна' }) }
  let!(:pending) do
    CrmCard.create!(kind: 'lead', author: agent, status: 'pending_review', submitted_at: 1.hour.ago,
                    payload: { 'name' => 'Борис' })
  end
  let!(:failed) { CrmCard.create!(kind: 'object', author: agent, status: 'export_failed', payload: { 'owner_name' => 'Вера' }) }

  def run(user, chat_type: 'private')
    message = { 'chat' => { 'id' => user.tg_user_id, 'type' => chat_type }, 'from' => { 'id' => user.tg_user_id },
                'message_id' => 5, 'text' => '/cards' }
    described_class.new(message: message, args: '', tg_user: user, client: tg_client).call
  end

  it 'сотруднику — только свои черновики и возвраты, с кнопками' do
    run(agent)

    expect(sent.last[:text]).to include("##{draft.id}", 'Анна').and(satisfy { |t| !t.include?('Борис') })
    expect(sent.last[:keyboard].flatten.map { |b| b[:callback_data] }).to eq(["crm_card:#{draft.id}:view"])
  end

  it 'модератору — ещё очередь модерации и сбои выгрузки' do
    run(director)

    expect(sent.last[:text]).to include('⏳ На модерации', 'Борис', '⚠️ Сбои выгрузки', 'Вера')
    expect(sent.last[:keyboard].flatten.map { |b| b[:callback_data] })
      .to include("crm_card:#{pending.id}:view", "crm_card:#{failed.id}:view")
  end

  it 'в группе список не показывает: там имена клиентов' do
    run(agent, chat_type: 'supergroup')

    expect(sent.last[:text]).to include('только в личке')
    expect(sent.last[:text]).not_to include('Анна')
  end
end
```

- [ ] **Step 2: Прогнать — падает**

Run: `bin/rb --db bundle exec rspec spec/services/telegram/work_bot/commands/cards_spec.rb`
Expected: FAIL — `NameError: uninitialized constant Telegram::WorkBot::Commands::Cards`.

- [ ] **Step 3: Команда**

Создать `app/services/telegram/work_bot/commands/cards.rb`:

```ruby
# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # `/cards` — карточки CRM: у сотрудника свои черновики и возвраты, у
      # модератора ещё очередь модерации и сбои выгрузки. Только в личке:
      # в списке имена клиентов.
      class Cards < Base
        LIMIT = 10

        def handle
          unless message.dig('chat', 'type') == 'private'
            return reply('📋 Карточки CRM — только в личке с ботом: в списке имена клиентов.')
          end

          perms = ::CrmCards::Permissions.for(tg_user)
          return reply("🚫 #{escape_html(perms.denial)}") if perms.denial

          lines = ['📋 <b>Карточки CRM</b>']
          rows = []
          sections(perms).each do |title, cards|
            lines << '' << "<b>#{title}</b> (#{cards.size})"
            lines << 'Пусто.' if cards.empty?
            cards.each do |card|
              lines << "• #{escape_html(line_for(card))}"
              rows << [{ text: line_for(card).truncate(60), callback_data: "crm_card:#{card.id}:view" }]
            end
          end
          reply(lines.join("\n"), reply_markup: { inline_keyboard: rows })
        end

        private

        def sections(perms)
          list = [['📝 Мои черновики и возвраты',
                   ::CrmCard.where(author: tg_user, status: ::CrmCard::AUTHOR_EDITABLE).order(updated_at: :desc)]]
          if perms.can?(:moderate)
            list << ['⏳ На модерации', ::CrmCard.status_pending_review.order(:submitted_at)]
            list << ['⚠️ Сбои выгрузки', ::CrmCard.where(status: %w[export_failed exporting]).order(:updated_at)]
          end
          list.map { |title, scope| [title, scope.limit(LIMIT).to_a] }
        end

        def line_for(card)
          name = card.payload['name'].presence || card.payload['owner_name'].presence || 'без имени'
          kind = card.kind_lead? ? 'заявка' : 'объект'
          "##{card.id} · #{kind} · #{name} · #{::CrmCard::STATUS_LABELS[card.status]}"
        end
      end
    end
  end
end
```

- [ ] **Step 4: Три реестра**

В `app/services/telegram/work_bot/router.rb` заменить:

```ruby
        '/bargain' => Commands::Bargain,
```

на:

```ruby
        '/bargain' => Commands::Bargain,
        # Карточки CRM через модерацию: черновики, очередь модератора, сбои выгрузки.
        '/cards' => Commands::Cards,
```

В `app/services/telegram/work_bot/commands/help.rb` заменить:

```ruby
          ['/bargain',      :staff,
           'Покупатель назвал цену — предупредить руководителя перед звонком: <code>/bargain 5,2 млн</code>'],
```

на:

```ruby
          ['/bargain',      :staff,
           'Покупатель назвал цену — предупредить руководителя перед звонком: <code>/bargain 5,2 млн</code>'],
          ['/cards',        :staff,
           'Карточки CRM (в личке): мои черновики и возвраты; у модератора — очередь и сбои выгрузки'],
```

В `config/telegram_bot_commands.yml` заменить:

```yaml
  - { cmd: bargain,      tier: staff,    group: true,  desc: 'Торг на объекте: /bargain 5,2 млн — руководитель получит карточку до звонка' }
```

на:

```yaml
  - { cmd: bargain,      tier: staff,    group: true,  desc: 'Торг на объекте: /bargain 5,2 млн — руководитель получит карточку до звонка' }
  - { cmd: cards,        tier: staff,    group: false, desc: 'Карточки CRM: черновики, модерация, сбои выгрузки' }
```

- [ ] **Step 5: Прогнать — зелёные, реестры согласованы**

Run: `bin/rb --db bundle exec rspec spec/services/telegram/work_bot/commands/cards_spec.rb spec/services/telegram/work_bot/command_registries_spec.rb spec/services/telegram/work_bot/router_spec.rb`
Expected: 0 failures.

- [ ] **Step 6: Линт и коммит**

Run: `bin/rb bundle exec rubocop -a app/services/telegram/work_bot/commands/cards.rb app/services/telegram/work_bot/router.rb app/services/telegram/work_bot/commands/help.rb spec/services/telegram/work_bot/commands/cards_spec.rb`

```bash
git add app/services/telegram/work_bot/commands/cards.rb app/services/telegram/work_bot/router.rb \
        app/services/telegram/work_bot/commands/help.rb config/telegram_bot_commands.yml \
        spec/services/telegram/work_bot/commands/cards_spec.rb
git commit -m "feat(work_bot): /cards — карточки CRM и очередь модерации в личке"
```

> **Конец стека C.** PR «Telegram: заявки» → CI → `/code-review` → правки. С этого PR заявки с сайта могут доходить до CRM — выкатывать только после Task 16, шаги 1–3.

---

## Стек D — объекты

### Task 13: Поля объекта и правила площадей, этажей, договора

**Files:**
- Modify: `app/services/crm_cards/schema.rb` (`CONTRACT_TYPES`, `OBJECT`, `KINDS`)
- Modify: `app/services/crm_cards/checker.rb` (`CONDITIONAL_MESSAGES`, `.conditionally_required`, `#object_rules`)
- Test: `spec/services/crm_cards/checker_object_spec.rb`

**Interfaces:**
- Consumes: `Schema`, `FieldValue`, `Checker` (Task 4).
- Produces: `Schema.for('object')` — поля `owner_name`, `owner_phone`, `action`, `realty_type`, `address`, `price`, `area_common`, `area_living`, `area_kitchen`, `area_land`, `rooms`, `floor`, `floors_total`, `contract_type`, `contract_number`, `comment` (в этом порядке — мастер спрашивает условные поля после тех, от которых они зависят). `Schema::CONTRACT_TYPES`.
- Produces: `CrmCards::Checker.conditionally_required(values) → Array<String>` — ключи, обязательные при данных значениях: `area_common` (тип задан и не участок), `area_land` (участок), `rooms` (квартира), `contract_number` (`agent` | `ad_agreement`).

- [ ] **Step 1: Спека (красная)**

Создать `spec/services/crm_cards/checker_object_spec.rb`:

```ruby
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CrmCards::Checker, 'карточка объекта' do
  let(:author) { TelegramUser.create!(tg_user_id: 98_961, status: 'active') }
  let(:flat) do
    { 'owner_name' => 'Иванов Пётр', 'owner_phone' => '79100001122', 'action' => 'sale', 'realty_type' => 'flat',
      'address' => 'Рязань, ул. Есенина, 29', 'price' => 5_500_000, 'area_common' => 54.3, 'area_living' => 30,
      'area_kitchen' => 9, 'rooms' => 2, 'floor' => 3, 'floors_total' => 5,
      'contract_type' => 'agent', 'contract_number' => 'А-17/26' }
  end

  def check(payload)
    described_class.call(CrmCard.new(kind: 'object', author: author, payload: payload))
  end

  it 'полная квартира — без замечаний' do
    expect(check(flat)).to eq([])
  end

  it 'общая площадь меньше суммы жилой и кухни' do
    expect(check(flat.merge('area_common' => 35))).to contain_exactly(
      a_hash_including('field' => 'area_common', 'message' => a_string_including('меньше суммы жилой и кухни (39 м²)'))
    )
  end

  it 'этаж выше этажности дома' do
    expect(check(flat.merge('floor' => 7))).to contain_exactly(
      a_hash_including('field' => 'floor', 'message' => 'Этаж 7 выше этажности дома (5).')
    )
  end

  it 'агентский договор без номера' do
    expect(check(flat.except('contract_number'))).to contain_exactly(
      a_hash_including('field' => 'contract_number', 'message' => a_string_including('нужен номер договора'))
    )
  end

  it 'устная договорённость номера не требует' do
    expect(check(flat.merge('contract_type' => 'verbal').except('contract_number'))).to eq([])
  end

  it 'квартира без числа комнат' do
    expect(check(flat.except('rooms'))).to contain_exactly(a_hash_including('field' => 'rooms'))
  end

  it 'участок: вместо общей площади — площадь участка' do
    land = flat.merge('realty_type' => 'land')
               .except('area_common', 'area_living', 'area_kitchen', 'rooms', 'floor', 'floors_total')

    expect(check(land)).to contain_exactly(a_hash_including('field' => 'area_land'))
    expect(check(land.merge('area_land' => 8))).to eq([])
  end

  it 'conditionally_required знает условия' do
    expect(described_class.conditionally_required('realty_type' => 'flat', 'contract_type' => 'ad_agreement'))
      .to eq(%w[area_common rooms contract_number])
    expect(described_class.conditionally_required('realty_type' => 'land')).to eq(%w[area_land])
    expect(described_class.conditionally_required({})).to eq([])
  end
end
```

- [ ] **Step 2: Прогнать — падает**

Run: `bin/rb --db bundle exec rspec spec/services/crm_cards/checker_object_spec.rb`
Expected: FAIL — `KeyError: key not found: "object"`.

- [ ] **Step 3: Поля объекта**

В `app/services/crm_cards/schema.rb` заменить:

```ruby
    KINDS = { 'lead' => LEAD }.freeze
```

на:

```ruby
    CONTRACT_TYPES = [
      ['Агентский договор', 'agent'], ['Соглашение на рекламу', 'ad_agreement'], ['Устная договорённость', 'verbal']
    ].freeze

    # Минимум формы «Создать объект Продавца» (ТЗ плагина topnlab-crm, §6) для
    # ручного внесения. Порядок важен: условно обязательные поля (комнаты,
    # площадь участка, номер договора) идут после тех, от которых зависят, —
    # мастер решает, спрашивать ли их, по уже данным ответам.
    OBJECT = [
      Field.new(key: 'owner_name', label: 'Собственник', type: :string, required: true, max: 255),
      Field.new(key: 'owner_phone', label: 'Телефон собственника', type: :phone, required: true, hint: PHONE_HINT),
      Field.new(key: 'action', label: 'Сделка', type: :choice, required: true, options: ACTIONS),
      Field.new(key: 'realty_type', label: 'Тип объекта', type: :choice, required: true, options: REALTY_TYPES),
      Field.new(key: 'address', label: 'Адрес', type: :string, required: true, min: 10, max: 255,
                hint: 'Населённый пункт, улица, дом — как в документах.'),
      Field.new(key: 'price', label: 'Цена, ₽', type: :decimal, required: true),
      Field.new(key: 'area_common', label: 'Общая площадь, м²', type: :decimal, required: false),
      Field.new(key: 'area_living', label: 'Жилая площадь, м²', type: :decimal, required: false),
      Field.new(key: 'area_kitchen', label: 'Кухня, м²', type: :decimal, required: false),
      Field.new(key: 'area_land', label: 'Участок, сот.', type: :decimal, required: false),
      Field.new(key: 'rooms', label: 'Комнат', type: :integer, required: false),
      Field.new(key: 'floor', label: 'Этаж', type: :integer, required: false),
      Field.new(key: 'floors_total', label: 'Этажей в доме', type: :integer, required: false),
      Field.new(key: 'contract_type', label: 'Договор с собственником', type: :choice, required: true,
                options: CONTRACT_TYPES),
      Field.new(key: 'contract_number', label: 'Номер договора', type: :string, required: false, max: 64),
      Field.new(key: 'comment', label: 'Комментарий', type: :text, required: false, max: 1000)
    ].freeze

    KINDS = { 'lead' => LEAD, 'object' => OBJECT }.freeze
```

- [ ] **Step 4: Правила объекта**

В `app/services/crm_cards/checker.rb` заменить:

```ruby
    def self.call(card)
      new(card).call
    end
```

на:

```ruby
    CONDITIONAL_MESSAGES = {
      'area_common' => 'не заполнено — для этого типа объекта нужна общая площадь',
      'area_land' => 'не заполнено — для участка нужна площадь участка',
      'rooms' => 'не заполнено — для квартиры укажи число комнат',
      'contract_number' => 'не заполнено — для агентского договора и соглашения на рекламу нужен номер договора'
    }.freeze

    def self.call(card)
      new(card).call
    end

    # Поля объекта, обязательные при данных значениях других полей. Нужны и
    # проверке, и мастеру: он спрашивает эти поля, а прочие необязательные
    # оставляет на «Изменить поле».
    # @return [Array<String>]
    def self.conditionally_required(values)
      type = values['realty_type'].to_s
      keys = []
      keys << (type == 'land' ? 'area_land' : 'area_common') if type.present?
      keys << 'rooms' if type == 'flat'
      keys << 'contract_number' if %w[agent ad_agreement].include?(values['contract_type'].to_s)
      keys
    end
```

Там же заменить:

```ruby
      errors.concat(lead_rules) if @card.kind_lead?
```

на:

```ruby
      errors.concat(lead_rules) if @card.kind_lead?
      errors.concat(object_rules) if @card.kind_object?
```

И добавить приватные методы перед `#blank_value?`:

```ruby
    # Правила формы CRM (ТЗ плагина, §6): общая площадь не меньше жилой и
    # кухни, этаж не выше дома, номер обязателен для договоров с подписью.
    def object_rules
      errors = self.class.conditionally_required(@values).filter_map do |key|
        [key, CONDITIONAL_MESSAGES.fetch(key)] if blank_value?(@values[key])
      end
      common, living, kitchen = @values.values_at('area_common', 'area_living', 'area_kitchen').map(&:to_f)
      if common.positive? && living + kitchen > common
        errors << ['area_common',
                   "Общая площадь #{area(common)} м² меньше суммы жилой и кухни (#{area(living + kitchen)} м²)."]
      end
      floor, total = @values.values_at('floor', 'floors_total').map(&:to_i)
      errors << ['floor', "Этаж #{floor} выше этажности дома (#{total})."] if floor.positive? && total.positive? && floor > total
      errors
    end

    def area(value)
      ActiveSupport::NumberHelper.number_to_rounded(value, precision: 2, strip_insignificant_zeros: true, separator: ',')
    end
```

- [ ] **Step 5: Прогнать — зелёные, заявка не задета**

Run: `bin/rb --db bundle exec rspec spec/services/crm_cards/checker_object_spec.rb spec/services/crm_cards/checker_spec.rb`
Expected: `17 examples, 0 failures`.

- [ ] **Step 6: Линт и коммит**

Run: `bin/rb bundle exec rubocop -a app/services/crm_cards/schema.rb app/services/crm_cards/checker.rb spec/services/crm_cards/checker_object_spec.rb`

```bash
git add app/services/crm_cards/schema.rb app/services/crm_cards/checker.rb spec/services/crm_cards/checker_object_spec.rb
git commit -m "feat(crm_cards): поля объекта и правила площадей, этажей и договора"
```

### Task 14: Мастер нового объекта и пункт меню

**Files:**
- Create: `app/services/telegram/work_bot/wizard/crm_object_card_flow.rb`
- Modify: `app/services/telegram/work_bot/wizard/engine.rb` (`FLOWS`)
- Modify: `app/services/telegram/work_bot/wizard/menu.rb` (`.keyboard`)
- Test: `spec/services/telegram/work_bot/wizard/crm_object_card_flow_spec.rb`

**Interfaces:**
- Consumes: `CrmCardSupport` (Task 9), `Workflow#create_object_card!` (Task 8), `Checker.conditionally_required` (Task 13).
- Produces: мастер `crm_object` (старт `wiz:s:crm_object`, без сида); кнопка «🏠 Новый объект в CRM» в «☰ Что сделать?» у сотрудников с `create_object`.

- [ ] **Step 1: Спека (красная)**

Создать `spec/services/telegram/work_bot/wizard/crm_object_card_flow_spec.rb`:

```ruby
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Wizard::CrmObjectCardFlow do
  include_context 'wizard DM harness'

  before { stub_crm_positions }

  let!(:agent) { crm_staff(tg_user_id: 98_971, username: 'irina') }

  it 'меню показывает «Новый объект» только тем, кому CRM разрешает заводить объекты' do
    intern = crm_staff(tg_user_id: 98_972, username: 'intern', position: '89878')
    labels = ->(user) { Telegram::WorkBot::Wizard::Menu.keyboard(user).flatten.map { |b| b[:text] } }

    expect(labels.call(agent)).to include('🏠 Новый объект в CRM')
    expect(labels.call(intern)).not_to include('🏠 Новый объект в CRM')
  end

  it 'квартира по агентскому договору: спрашивает площадь, комнаты и номер договора, участок — нет' do
    tap_callback('wiz:s:crm_object', user: agent)
    expect(last_text).to include('Собственник?')

    say('Иванов Пётр', user: agent)
    say('+7 910 000-11-22', user: agent)
    press('Продажа', user: agent)
    press('Квартира', user: agent)
    say('Рязань, ул. Есенина, 29', user: agent)
    say('5 500 000', user: agent)
    expect(last_text).to include('Общая площадь, м²?')

    say('54,3', user: agent)
    expect(last_text).to include('Комнат?')

    say('2', user: agent)
    press('Агентский', user: agent)
    expect(last_text).to include('Номер договора?')

    say('А-17/26', user: agent)
    expect { press('Сохранить', user: agent) }.to change(CrmCard.kind_object, :count).by(1)

    card = CrmCard.kind_object.last
    expect(card.author).to eq(agent)
    expect(card.payload).to include('owner_phone' => '79100001122', 'price' => 5_500_000, 'area_common' => 54.3,
                                    'rooms' => 2, 'contract_number' => 'А-17/26')
    expect(card.payload).not_to have_key('area_land')
    expect(last_text).to include('Объект в CRM', '✅ пройдена')
  end

  it 'стажёру без права на объекты мастер отказывает до первого вопроса' do
    intern = crm_staff(tg_user_id: 98_973, username: 'intern', position: '89878')

    tap_callback('wiz:s:crm_object', user: intern)

    expect(last_text).to include('право заводить объекты')
    expect(CrmCard.count).to eq(0)
  end
end
```

- [ ] **Step 2: Прогнать — падает**

Run: `bin/rb --db bundle exec rspec spec/services/telegram/work_bot/wizard/crm_object_card_flow_spec.rb`
Expected: FAIL — нет кнопки в меню, «Неизвестный мастер».

- [ ] **Step 3: Мастер**

Создать `app/services/telegram/work_bot/wizard/crm_object_card_flow.rb`:

```ruby
# frozen_string_literal: true

module Telegram
  module WorkBot
    module Wizard
      # Мастер «Новый объект в CRM». Спрашивает обязательное и условно
      # обязательное (комнаты для квартиры, номер для агентского договора);
      # прочее — через «Изменить поле», чтобы заводить объект по телефону
      # не приходилось через шестнадцать вопросов.
      #
      # До шлюза к внутреннему API объект в CRM вносится вручную после
      # одобрения (CrmCardManualExportFlow).
      class CrmObjectCardFlow < Flow
        include CrmCardSupport

        flow 'crm_object', 'Новый объект в CRM'

        def steps
          ::CrmCards::Schema.for('object').map { |field| field_step(field) } +
            [Flow::Step.new(id: 'confirm', kind: :confirm,
                            prompt: 'Сохранить карточку объекта? Дальше — машинная проверка.',
                            confirm_label: '💾 Сохранить и проверить')]
        end

        def skip?(step)
          field = ::CrmCards::Schema.field('object', step.id)
          return false if field.nil? || field.required

          !::CrmCards::Checker.conditionally_required(answers).include?(field.key)
        end

        def gate
          return "🚫 #{escape_html(permissions.denial)}" if permissions.denial
          return '🚫 Твоей должности в CRM не выдано право заводить объекты.' unless permissions.can?(:create_object)

          nil
        end

        def accept(step, value, manual: false)
          field = ::CrmCards::Schema.field('object', step.id)
          field ? accept_field(field, value) : [value, nil]
        end

        def finish
          result_view(workflow.create_object_card!(actor: tg_user, values: answers))
        end

        private

        def answers
          ::CrmCards::Schema.for('object').to_h { |f| [f.key, ctx[f.key]] }.compact
        end
      end
    end
  end
end
```

- [ ] **Step 4: Регистрация и меню**

В `app/services/telegram/work_bot/wizard/engine.rb` заменить:

```ruby
          'crm_approve' => 'Telegram::WorkBot::Wizard::CrmCardApproveFlow'
        }.freeze
```

на:

```ruby
          'crm_approve' => 'Telegram::WorkBot::Wizard::CrmCardApproveFlow',
          'crm_object' => 'Telegram::WorkBot::Wizard::CrmObjectCardFlow'
        }.freeze
```

(`SEED_STEP` не меняется: объект заводится из меню, без id.)

В `app/services/telegram/work_bot/wizard/menu.rb` заменить:

```ruby
          rows << [{ text: '❌ Закрыть лид', callback_data: 'wiz:s:close' }] if tg_user&.manager_or_director?
          rows
```

на:

```ruby
          rows << [{ text: '❌ Закрыть лид', callback_data: 'wiz:s:close' }] if tg_user&.manager_or_director?
          # Право на объекты — из должности в CRM, а не из роли в боте.
          if tg_user && ::CrmCards::Permissions.for(tg_user).can?(:create_object)
            rows << [{ text: '🏠 Новый объект в CRM', callback_data: 'wiz:s:crm_object' }]
          end
          rows
```

- [ ] **Step 5: Прогнать — зелёная**

Run: `bin/rb --db bundle exec rspec spec/services/telegram/work_bot/wizard`
Expected: 0 failures (новая спека — `3 examples`, `engine_spec` не задет).

- [ ] **Step 6: Линт и коммит**

Run: `bin/rb bundle exec rubocop -a app/services/telegram/work_bot/wizard/crm_object_card_flow.rb app/services/telegram/work_bot/wizard/engine.rb app/services/telegram/work_bot/wizard/menu.rb spec/services/telegram/work_bot/wizard/crm_object_card_flow_spec.rb`

```bash
git add app/services/telegram/work_bot/wizard/crm_object_card_flow.rb app/services/telegram/work_bot/wizard/engine.rb \
        app/services/telegram/work_bot/wizard/menu.rb spec/services/telegram/work_bot/wizard/crm_object_card_flow_spec.rb
git commit -m "feat(work_bot): мастер нового объекта в CRM по праву из должности"
```

### Task 15: Ручное внесение одобренного объекта

**Files:**
- Create: `app/services/telegram/work_bot/wizard/crm_card_manual_export_flow.rb`
- Modify: `app/services/telegram/work_bot/wizard/engine.rb` (`FLOWS`, `SEED_STEP`)
- Test: `spec/services/telegram/work_bot/wizard/crm_card_manual_export_flow_spec.rb`

**Interfaces:**
- Consumes: `Workflow#record_export!(card, crm_id:, mode: 'manual', actor:)` (Task 8), `Notifier#approved` (Task 7), `CardView::MANUAL_EXPORT_HINT` (Task 6).
- Produces: мастер `crm_manual` (старт `wiz:s:crm_manual:<card_id>`, шаг-сид `card`).

- [ ] **Step 1: Спека (красная)**

Создать `spec/services/telegram/work_bot/wizard/crm_card_manual_export_flow_spec.rb`:

```ruby
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Wizard::CrmCardManualExportFlow do
  include_context 'wizard DM harness'

  before { stub_crm_positions }

  let!(:agent)    { crm_staff(tg_user_id: 98_981, username: 'irina') }
  let!(:director) { crm_staff(tg_user_id: 98_982, username: 'oksana', position: '89884', role: 'director') }
  let!(:card) do
    CrmCard.create!(kind: 'object', author: agent, reviewer: director, status: 'approved', export_mode: 'manual',
                    checked_at: Time.current,
                    payload: { 'owner_name' => 'Иванов Пётр', 'owner_phone' => '79100001122', 'action' => 'sale',
                               'realty_type' => 'flat', 'address' => 'Рязань, ул. Есенина, 29', 'price' => 5_500_000,
                               'area_common' => 54.3, 'rooms' => 2, 'contract_type' => 'verbal' })
  end

  it 'автор получает паспорт для внесения и отмечает номер карточки CRM' do
    CrmCards::Notifier.new(client: tg_client).approved(card)
    expect(last_text).to include('Объект одобрен', 'Внеси объект в CRM вручную', 'Собственник: Иванов Пётр')

    press('Внесено в CRM', user: agent)
    say('номер 123', user: agent)
    expect(last_text).to include('только цифры')

    say('998877', user: agent)
    press('Подтвердить', user: agent)

    expect(card.reload).to have_attributes(status: 'exported', crm_id: '998877', export_mode: 'manual')
    expect(card.transitions.last).to have_attributes(to_status: 'exported', actor_id: agent.id)
  end

  it 'посторонний отметить внесение не может' do
    petr = crm_staff(tg_user_id: 98_983, username: 'petr')

    tap_callback("wiz:s:crm_manual:#{card.id}", user: petr)

    expect(last_text).to include('автор карточки или модератор')
    expect(card.reload).to be_status_approved
  end
end
```

- [ ] **Step 2: Прогнать — падает**

Run: `bin/rb --db bundle exec rspec spec/services/telegram/work_bot/wizard/crm_card_manual_export_flow_spec.rb`
Expected: FAIL — «Неизвестный мастер» на кнопке «Внесено в CRM».

- [ ] **Step 3: Мастер**

Создать `app/services/telegram/work_bot/wizard/crm_card_manual_export_flow.rb`:

```ruby
# frozen_string_literal: true

module Telegram
  module WorkBot
    module Wizard
      # «Объект внесён в CRM»: автор (или модератор) вносит одобренный объект
      # в интерфейсе Topnlab и вводит здесь номер карточки. Без номера объект
      # остаётся «одобрен» и виден в /cards — «забыли внести» не теряется.
      class CrmCardManualExportFlow < Flow
        include CrmCardSupport

        flow 'crm_manual', 'Объект внесён в CRM'

        def steps
          [
            Flow::Step.new(id: 'crm_id', kind: :input, prompt: "Номер карточки объекта ##{ctx['card']} в CRM?",
                           hint: 'Цифры из адреса карточки в Topnlab: …/object-card/<номер>.'),
            Flow::Step.new(id: 'confirm', kind: :confirm,
                           prompt: "Объект ##{ctx['card']} внесён в CRM под номером #{escape_html(ctx['crm_id'])}?",
                           confirm_label: '✅ Подтвердить')
          ]
        end

        def gate
          return '⚠️ Карточка не найдена.' unless card
          return "🚫 #{escape_html(permissions.denial)}" if permissions.denial
          unless card.author_id == tg_user.id || permissions.can?(:moderate)
            return '🚫 Отметить внесение в CRM может автор карточки или модератор.'
          end
          unless card.kind_object? && card.status_approved?
            return "ℹ️ Карточка ##{card.id} не ждёт ручного внесения — #{::CrmCard::STATUS_LABELS[card.status]}."
          end

          nil
        end

        def accept(step, value, manual: false)
          return [value, nil] unless step.id == 'crm_id'

          digits = value.to_s.strip
          digits.match?(/\A\d{1,12}\z/) ? [digits, nil] : [nil, 'Номер карточки — только цифры, без пробелов и букв.']
        end

        def finish
          return { text: '⚠️ Карточка не найдена — ничего не отмечено.' } unless card

          result = workflow.record_export!(card, crm_id: ctx['crm_id'], mode: 'manual', actor: tg_user)
          return { text: "⚠️ #{escape_html(result.error)}" } unless result.ok?

          { text: "🟢 Объект ##{card.id} отмечен как внесённый в CRM: #{escape_html(result.card.crm_id)}." }
        end
      end
    end
  end
end
```

- [ ] **Step 4: Регистрация**

В `app/services/telegram/work_bot/wizard/engine.rb` заменить:

```ruby
          'crm_object' => 'Telegram::WorkBot::Wizard::CrmObjectCardFlow'
        }.freeze

        # Какой шаг получает id, пришедший с кнопкой на карточке.
        SEED_STEP = { 'task' => 'lead', 'close' => 'lead', 'reopen' => 'task',
                      'crm_lead' => 'lead', 'crm_edit' => 'card', 'crm_rework' => 'card',
                      'crm_approve' => 'card' }.freeze
```

на:

```ruby
          'crm_object' => 'Telegram::WorkBot::Wizard::CrmObjectCardFlow',
          'crm_manual' => 'Telegram::WorkBot::Wizard::CrmCardManualExportFlow'
        }.freeze

        # Какой шаг получает id, пришедший с кнопкой на карточке.
        SEED_STEP = { 'task' => 'lead', 'close' => 'lead', 'reopen' => 'task',
                      'crm_lead' => 'lead', 'crm_edit' => 'card', 'crm_rework' => 'card',
                      'crm_approve' => 'card', 'crm_manual' => 'card' }.freeze
```

- [ ] **Step 5: Полный прогон затронутого**

Run: `bin/rb --db bundle exec rspec spec/services/telegram/work_bot/wizard/crm_card_manual_export_flow_spec.rb`
Expected: `2 examples, 0 failures`.

Run: `bin/rb --db bundle exec rspec spec/models/crm_card_spec.rb spec/services/crm_cards spec/jobs/crm_cards spec/services/telegram/work_bot spec/services/lead`
Expected: 0 failures.

Run: `bin/rb bundle exec rubocop --parallel` и `bin/rb bundle exec brakeman --exit-on-warn --quiet --format text`
Expected: без замечаний.

- [ ] **Step 6: Коммит**

```bash
git add app/services/telegram/work_bot/wizard/crm_card_manual_export_flow.rb \
        app/services/telegram/work_bot/wizard/engine.rb \
        spec/services/telegram/work_bot/wizard/crm_card_manual_export_flow_spec.rb
git commit -m "feat(work_bot): ручное внесение одобренного объекта в CRM с номером карточки"
```

> **Конец стека D.** PR «объекты» → CI → `/code-review` → правки.

---

## Task 16: Запуск — данные прав, выкатка, проверка на живом

Кода нет; каждый шаг — действие человека или команда на прод-хосте. Выполняет руководитель вместе с исполнителем. Порядок обязателен: без шагов 1–3 конвейер честно откажет «модераторов нет», а заявки с сайта так и не дойдут до CRM.

- [ ] **Step 1: Утвердить таблицу должностей**

Руководитель смотрит `config/crm_permissions.yml` (spec §10, п. 1): Ген. директор — всё; Агент — заявки и объекты; Стажёр — только заявки; Конструктор, Аудитор, Юрист — ничего. Правки — отдельным PR до выкатки.

- [ ] **Step 2: Выкатить стеки A–D**

Процедура — `.claude/memory/techContext.md`, раздел про деплой. В стеке A есть миграция: после обновления кода на прод-хосте — `/usr/bin/docker compose exec -T web bin/rails db:migrate`, затем `git checkout -- db/structure.sql` (прод-база переписывает файл, см. auto-memory «Прод-БД: 5 расширений против 7»). Перезапуск `web` и `sidekiq`.

- [ ] **Step 3: Починить привязки и проверить права**

Run (прод-хост, только чтение): `/usr/bin/docker compose exec -T web bin/rails crm_cards:permissions`
Expected до починки (данные 14.09.26, spec §8): «⚠️ Модераторов нет»; один директор бота — «нет прав: Нет привязки к CRM»; второй — «CRM: Конструктор → нет прав»; один сотрудник — «двум разным учёткам» или «не активна (blocked)».

Действия:
1. Директор, чья учётка в CRM — «Генеральный директор», пишет боту в личку `/whoami <email этой учётки>` и вводит код из письма.
2. Сотрудник, привязанный к заблокированной учётке «Юрист», — руководитель решает: разблокировать в CRM или перепривязать через `/whoami` к действующей учётке.
3. Повторить команду отчёта.

Expected после: строка `Модераторы: @…` с директором; у агентов — `create_lead, create_object`; предупреждений о расхождении названий нет или они осознанно приняты.

- [ ] **Step 4: Проверка на живом — заявка без выгрузки**

1. Взять реальный свежий лид с сайта, назначенный агенту; агент после звонка — `/stage контакт`.
2. Агент: кнопка «📋 Карточка CRM» под лидом → мастер в личке → «💾 Сохранить и проверить» → «📤 На модерацию».
   Expected: у директора в личке карточка с кнопками «Изменить поле / На доработку / Одобрить»; под лидом в группе — «⏳ На модерации · CRM», без телефона.
3. Директор: «↩️ На доработку» с комментарием. Expected: агенту пришёл комментарий, кнопка под лидом — «↩️ Карточка CRM: доработать».
4. Агент дорабатывает и отправляет снова; директор — «✅ Одобрить и выгрузить».
   Expected: в течение минуты карточка «🟢 В CRM #<номер>», в Topnlab — заявка с ответственным-агентом; у `Inquiry` лида заполнен `crm_id`.
   Если пришло предупреждение «ответственный не назначен» — поставить ответственного в CRM руками и проверить email агента в `/whoami`.

- [ ] **Step 5: Проверка на живом — объект**

Агент: «☰ Что сделать?» → «🏠 Новый объект в CRM» → мастер → на модерацию; директор одобряет; агент вносит объект в Topnlab по «паспорту» и отмечает номер через «📥 Внесено в CRM».
Expected: карточка «🟢 В CRM #<номер>»; через вебхук Topnlab объект появляется в каталоге сайта (`TopnlabPropertyImportJob`).

- [ ] **Step 6: Документация**

Обновить `.claude/memory/progress.md` (что в проде) и `.claude/memory/activeContext.md` (фокус) одним PR: конвейер карточек CRM включён, модератор(ы), таблица должностей утверждена <дата dd.MM.yy>.
