# Служба сбора данных о ЖК (S1+S2) — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Еженедельно находить жилые комплексы Рязани, которых нет в справочнике, заводить их черновиками с проверяемой фактурой, поддерживать заведённые в актуальном состоянии и показывать редактору поля, где источники противоречат друг другу.

**Architecture:** Python-служба в `services/zhk-registry/` обходит источники и нормализует найденное в «наблюдения»; решение, что из этого применить, целиком остаётся в Rails за вебхуком `POST /webhooks/zhk_ingest`. Провенанс пишется по каждому полю, расхождение вычисляется запросом к фактам, цена за м² копится append-only.

**Tech Stack:** Rails 8.1.3.1 / Ruby 3.4.10 / PostgreSQL 15 + PostGIS; Python 3 (stdlib `unittest`, `requests`, `beautifulsoup4`, `pydantic`, `python-dotenv`); Sidekiq не используется — служба ходит по крону.

**Spec:** `docs/superpowers/specs/2026-09-07-zhk-registry-design.md`

## Global Constraints

- Работать только в worktree `/home/q/victory-registry`, ветка `claude/zhk-registry`. Чужие worktree и `/home/q/victory` — read-only (последний это live-prod bind-mount).
- Ruby-файлы: `# frozen_string_literal: true` первой строкой, одинарные кавычки, комментарии по-русски.
- Enum'ы — всегда `prefix: true` (правило #2 `CLAUDE.md`), русский перевод значений в комментарии рядом.
- Даты в UI, сообщениях и комментариях — `dd.MM.yy`.
- Soft-delete (`deleted_at` + `default_scope`) — правило #1 `CLAUDE.md`, но **к трём новым таблицам не применяется**: это журналы наблюдений, а не доменные сущности; удалять их пользователь не может в принципе, а `default_scope` на журнале мешал бы аудиту. Отступление осознанное, зафиксировать комментарием в каждой модели.
- В базу пишет **только Rails**. Python не имеет доступа к БД и не принимает решений о применении.
- Уверенность источника в БД не хранится нигде. Вес живёт в конфиге адаптера.
- `zhk_price_points` — append-only, без пересчётов при записи, с обязательным `kind`.
- Импорты между службами в `services/` запрещены.
- Прогон спеков: `bin/rb --db bundle exec rspec <path>`. Линтер: `bin/rb bundle exec rubocop <paths>`. Питоновские тесты: `cd services/zhk-registry && python3 -m unittest discover -v`.
- Коммит после каждой задачи; в конце сообщения — трейлеры `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>` и `Claude-Session: https://claude.ai/code/session_01S9mWBdhz3ZMY2VKhpKrv1R`.

## File Structure

**Rails, новое:**

| Файл | Ответственность |
|---|---|
| `db/migrate/*_create_zhk_observations.rb` | журнал сырья с уникальностью по digest |
| `db/migrate/*_create_zhk_facts.rb` | провенанс: поле × источник |
| `db/migrate/*_create_zhk_price_points.rb` | append-only ряд цены за м² |
| `app/models/zhk_observation.rb`, `zhk_fact.rb`, `zhk_price_point.rb` | модели журналов |
| `app/services/zhk/fact_applier.rb` | единственная реализация правила «заполняем только пустое» |
| `app/services/zhk/matcher.rb` | сопоставление наблюдения с существующим ЖК |
| `app/services/zhk/ingest.rb` | применение одного наблюдения, отчёт по нему |
| `app/services/zhk/discrepancies.rb` | расхождения как запрос к фактам |
| `app/services/zhk/run_summary.rb` | сводка прогона + детектор молчащего источника |
| `app/controllers/webhooks/zhk_ingest_controller.rb` | приём батча и сводки |
| `app/controllers/admin/zhk_discrepancies_controller.rb` | экран расхождений |
| `app/views/admin/zhk_discrepancies/index.html.erb` | таблица расхождений |
| `spec/fixtures/zhk/observation_example.json` | **общий контракт**, читают обе стороны |

**Rails, правится:** `db/seeds/residential_complexes.rb` (переходит на `Zhk::FactApplier`), `config/routes.rb`, `app/models/residential_complex.rb` (три `has_many`).

**Python, новое (`services/zhk-registry/`):** `observation.py` (pydantic-модель наблюдения), `client.py` (отправка батчами), `sources/erz.py`, `sources/developer_sites.py`, `run.py` (оркестратор), `tests/` (unittest + HTML-фикстуры), `requirements.txt`, `.env.example`, `crontab.example`, `README.md`, `CLAUDE.md`.

---

### Task 1: Три журнальные таблицы и модели

**Files:**
- Create: `db/migrate/20260907120000_create_zhk_observations.rb`, `db/migrate/20260907120100_create_zhk_facts.rb`, `db/migrate/20260907120200_create_zhk_price_points.rb`
- Create: `app/models/zhk_observation.rb`, `app/models/zhk_fact.rb`, `app/models/zhk_price_point.rb`
- Modify: `app/models/residential_complex.rb` (добавить три `has_many` рядом с существующим `has_many :properties`)
- Test: `spec/models/zhk_observation_spec.rb`, `spec/models/zhk_price_point_spec.rb`

**Interfaces:**
- Produces: `ZhkObservation(source:, external_id:, url:, fetched_at:, payload:, digest:)`; `ZhkFact(residential_complex:, field:, value:, source:, url:, observed_at:)`; `ZhkPricePoint(residential_complex:, source:, observed_at:, price_per_sqm:, kind:, rooms:, url:)` с `enum :kind, { from: 0, median: 1 }, prefix: true`; `ResidentialComplex#zhk_facts`, `#zhk_price_points`.

- [ ] **Step 1: Написать падающий спек**

```ruby
# spec/models/zhk_observation_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ZhkObservation do
  let(:attrs) do
    { source: 'erz', external_id: 'erz:564336001', url: 'https://erzrf.ru/x',
      fetched_at: Time.current, payload: { 'name' => 'Скобелев' }, digest: 'a' * 64 }
  end

  it 'не допускает второй записи с тем же digest — на этом стоит идемпотентность' do
    described_class.create!(attrs)

    expect { described_class.create!(attrs) }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end

  it 'допускает то же наблюдение с изменившейся нагрузкой' do
    described_class.create!(attrs)

    expect { described_class.create!(attrs.merge(digest: 'b' * 64)) }.not_to raise_error
  end
end
```

```ruby
# spec/models/zhk_price_point_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ZhkPricePoint do
  it 'различает цену «от» и медиану — без этого ряд несравним сам с собой' do
    complex = create(:residential_complex)
    point = described_class.create!(residential_complex: complex, source: 'erz',
                                    observed_at: Time.current, price_per_sqm: 65_000,
                                    kind: :from)

    expect(point.kind_from?).to be true
    expect(point.kind_median?).to be false
  end
end
```

- [ ] **Step 2: Убедиться, что спеки падают**

Run: `bin/rb --db bundle exec rspec spec/models/zhk_observation_spec.rb spec/models/zhk_price_point_spec.rb`
Expected: FAIL, `uninitialized constant ZhkObservation`

- [ ] **Step 3: Написать миграции**

```ruby
# db/migrate/20260907120000_create_zhk_observations.rb
# frozen_string_literal: true

# Журнал сырья, как оно пришло от службы сбора. Две задачи: идемпотентность
# (тот же digest не переприменяется) и возможность через полгода ответить
# «откуда мы это взяли», не веря на слово.
class CreateZhkObservations < ActiveRecord::Migration[8.1]
  def change
    create_table :zhk_observations do |t|
      t.string   :source,      null: false
      t.string   :external_id, null: false
      t.string   :url
      t.datetime :fetched_at,  null: false
      t.jsonb    :payload,     null: false, default: {}
      t.string   :digest,      null: false
      t.timestamps
    end

    add_index :zhk_observations, %i[source external_id digest], unique: true,
              name: 'idx_zhk_observations_identity'
    add_index :zhk_observations, %i[source fetched_at]
  end
end
```

```ruby
# db/migrate/20260907120100_create_zhk_facts.rb
# frozen_string_literal: true

# Провенанс по полю: один ЖК × одно поле × один источник = одна строка.
# `value` строкой намеренно — журнал хранит то, что сказал источник, а
# типизация это забота потребителя.
class CreateZhkFacts < ActiveRecord::Migration[8.1]
  def change
    create_table :zhk_facts do |t|
      t.references :residential_complex, null: false, foreign_key: true
      t.string     :field,       null: false
      t.string     :value
      t.string     :source,      null: false
      t.string     :url
      t.datetime   :observed_at, null: false
      t.timestamps
    end

    add_index :zhk_facts, %i[residential_complex_id field]
    add_index :zhk_facts, %i[residential_complex_id field source], unique: true,
              name: 'idx_zhk_facts_identity'
  end
end
```

```ruby
# db/migrate/20260907120200_create_zhk_price_points.rb
# frozen_string_literal: true

# Append-only ряд цены за м². Никаких пересчётов при записи: тренды считает
# отдельная спека, когда наберётся хотя бы пара месяцев замеров.
class CreateZhkPricePoints < ActiveRecord::Migration[8.1]
  def change
    create_table :zhk_price_points do |t|
      t.references :residential_complex, null: false, foreign_key: true
      t.string     :source,        null: false
      t.datetime   :observed_at,   null: false
      t.integer    :price_per_sqm, null: false
      t.integer    :kind,          null: false, default: 0
      t.integer    :rooms
      t.string     :url
      t.timestamps
    end

    add_index :zhk_price_points, %i[residential_complex_id observed_at]
  end
end
```

- [ ] **Step 4: Написать модели**

```ruby
# app/models/zhk_observation.rb
# frozen_string_literal: true

# Сырьё от службы сбора (services/zhk-registry). Soft-delete здесь
# намеренно НЕ применяется вопреки общему правилу: это журнал, а не
# доменная сущность — пользователь его не удаляет, а default_scope мешал бы
# аудиту.
class ZhkObservation < ApplicationRecord
  validates :source, :external_id, :fetched_at, :digest, presence: true

  scope :for_source, ->(source) { where(source: source) }
end
```

```ruby
# app/models/zhk_fact.rb
# frozen_string_literal: true

# Откуда взято конкретное поле конкретного ЖК. Журнал — soft-delete не
# применяется (см. ZhkObservation).
class ZhkFact < ApplicationRecord
  belongs_to :residential_complex

  validates :field, :source, :observed_at, presence: true
end
```

```ruby
# app/models/zhk_price_point.rb
# frozen_string_literal: true

# Точка ряда цены за м². Журнал — soft-delete не применяется.
class ZhkPricePoint < ApplicationRecord
  belongs_to :residential_complex

  # _prefix per CLAUDE.md convention → point.kind_from?
  # from — цена «от» с сайта застройщика; median — медиана по выставленным
  # лотам у агрегатора. Величины разные, сравнивать можно только внутри
  # одного источника И одного kind.
  enum :kind, { from: 0, median: 1 }, prefix: true

  validates :source, :observed_at, :price_per_sqm, presence: true
  validates :price_per_sqm, numericality: { only_integer: true, greater_than: 0 }
end
```

Плюс в `app/models/residential_complex.rb`, сразу под `has_many :properties`:

```ruby
  # Журналы службы сбора. `dependent:` не ставим по той же причине, что и у
  # properties: мягкое удаление идёт через update!, а dependent висит на
  # destroy — он был бы мёртвым кодом.
  has_many :zhk_facts
  has_many :zhk_price_points
```

- [ ] **Step 5: Прогнать миграции и спеки**

Run: `bin/rb --db bin/rails db:migrate && bin/rb --db bin/rails db:test:prepare && bin/rb --db bundle exec rspec spec/models/zhk_observation_spec.rb spec/models/zhk_price_point_spec.rb`
Expected: PASS, 3 examples, 0 failures

- [ ] **Step 6: Линтер и коммит**

```bash
bin/rb bundle exec rubocop db/migrate app/models/zhk_observation.rb app/models/zhk_fact.rb app/models/zhk_price_point.rb app/models/residential_complex.rb
git add db/migrate db/schema.rb app/models spec/models/zhk_observation_spec.rb spec/models/zhk_price_point_spec.rb
git commit -m "feat(zhk): журналы наблюдений, фактов и цены за м²"
```

---

### Task 2: `Zhk::FactApplier` — одна реализация правила заполнения

Правило «заполняем только пустое, при расхождении оставляем пусто» сегодня живёт внутри сида. Вебхуку оно нужно тоже, а две похожие реализации расходятся тише, чем две разные.

**Files:**
- Create: `app/services/zhk/fact_applier.rb`
- Modify: `db/seeds/residential_complexes.rb` (цикл заполнения заменяется вызовом)
- Test: `spec/services/zhk/fact_applier_spec.rb`

**Interfaces:**
- Produces: `Zhk::FactApplier.apply(complex, attrs) → Array<Symbol>` — список полей, которые были заполнены (пустой массив = ничего не изменилось). `Zhk::FactApplier::FILLABLE → Array<Symbol>` — белый список полей.

- [ ] **Step 1: Написать падающий спек**

```ruby
# spec/services/zhk/fact_applier_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Zhk::FactApplier do
  let(:complex) { create(:residential_complex, developer: nil, address_patterns: []) }

  it 'заполняет пустое поле и сообщает, что заполнил' do
    filled = described_class.apply(complex, developer: 'Единство')

    expect(filled).to eq(%i[developer])
    expect(complex.developer).to eq('Единство')
  end

  it 'не трогает то, что уже заполнено — иначе прогон откатывал бы правки редактора' do
    complex.update!(developer: 'Правка редактора')

    filled = described_class.apply(complex, developer: 'Единство')

    expect(filled).to be_empty
    expect(complex.developer).to eq('Правка редактора')
  end

  # Регресс: у address_patterns дефолт [] — истинное значение, и заполнение
  # через `||=` молча пропускало бы массив.
  it 'считает пустой массив пустым значением' do
    described_class.apply(complex, address_patterns: ['ул. Льговская, д. 10'])

    expect(complex.address_patterns).to eq(['ул. Льговская, д. 10'])
  end

  it 'игнорирует поля вне белого списка' do
    filled = described_class.apply(complex, published: true, id: 999)

    expect(filled).to be_empty
    expect(complex.published).to be false
  end

  it 'игнорирует nil — источник промолчал, а не сообщил пустоту' do
    complex.update!(developer: 'Единство')

    expect(described_class.apply(complex, developer: nil)).to be_empty
    expect(complex.developer).to eq('Единство')
  end
end
```

- [ ] **Step 2: Убедиться, что спек падает**

Run: `bin/rb --db bundle exec rspec spec/services/zhk/fact_applier_spec.rb`
Expected: FAIL, `uninitialized constant Zhk::FactApplier`

- [ ] **Step 3: Реализовать**

```ruby
# app/services/zhk/fact_applier.rb
# frozen_string_literal: true

module Zhk
  # Единственная реализация правила «заполняем только пустое». Ею пользуются
  # и сид справочника, и приём наблюдений от службы сбора: две похожие
  # реализации разъезжаются тише, чем две разные.
  #
  # Ничего не сохраняет — вызывающий сам решает, когда `save!`.
  module FactApplier
    # Всё, что служба и сид имеют право заполнять. `published`, `body_blocks`
    # и слаг сюда не входят намеренно: это территория редактора.
    FILLABLE = %i[
      name district_slug developer address address_patterns
      built_from built_to buildings_count floors_min floors_max
      wall_material housing_class build_status
    ].freeze

    module_function

    # @return [Array<Symbol>] поля, которые были заполнены
    def apply(complex, attrs)
      attrs.filter_map do |field, value|
        field = field.to_sym
        next unless FILLABLE.include?(field)
        next if value.nil?
        # `blank?`, а не `||=`: у address_patterns дефолт [] — истинное
        # значение, и `||=` молча пропускал бы заполнение пустого массива.
        next if complex.public_send(field).present?

        complex.public_send(:"#{field}=", value)
        field
      end
    end
  end
end
```

- [ ] **Step 4: Перевести сид на общую реализацию**

В `db/seeds/residential_complexes.rb` цикл заполнения полей заменяется на вызов; комментарий про `blank?` переезжает в сервис, в сиде остаётся ссылка:

```ruby
  # Идемпотентность: заполняем только пустое. Правило и его обоснование —
  # в Zhk::FactApplier, общем с приёмом наблюдений от службы сбора.
  Zhk::FactApplier.apply(complex, attrs.except(:slug))
```

- [ ] **Step 5: Прогнать спеки сервиса и сида**

Run: `bin/rb --db bundle exec rspec spec/services/zhk/fact_applier_spec.rb spec/models/residential_complex_spec.rb`
Expected: PASS. Спеки сида (`rake zhk:seed`: идемпотентность, слаги, `address_patterns`, «не выдумывает фактуру») обязаны остаться зелёными — они и есть проверка того, что поведение не изменилось.

- [ ] **Step 6: Линтер и коммит**

```bash
bin/rb bundle exec rubocop app/services/zhk/fact_applier.rb db/seeds/residential_complexes.rb
git add app/services/zhk/fact_applier.rb db/seeds/residential_complexes.rb spec/services/zhk/fact_applier_spec.rb
git commit -m "refactor(zhk): правило заполнения — в общий Zhk::FactApplier"
```

---

### Task 3: `Zhk::Matcher` — сопоставление находки со справочником

**Files:**
- Create: `app/services/zhk/matcher.rb`
- Test: `spec/services/zhk/matcher_spec.rb`

**Interfaces:**
- Consumes: `ResidentialComplex` (скоупы `in_city`, `not_deleted`).
- Produces: `Zhk::Matcher.call(name:, city:, address: nil) → ResidentialComplex | nil`; `Zhk::Matcher.normalize(String) → String`.

- [ ] **Step 1: Написать падающий спек**

```ruby
# spec/services/zhk/matcher_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Zhk::Matcher do
  let!(:legenda) do
    create(:residential_complex, name: 'Легенда', city: 'Рязань',
                                 address_patterns: ['ул. Интернациональная, д. 20'])
  end

  it 'находит по имени независимо от кавычек, регистра и приставки ЖК' do
    expect(described_class.call(name: 'ЖК «ЛЕГЕНДА»', city: 'Рязань')).to eq(legenda)
  end

  it 'находит по адресному паттерну, когда имя записано иначе' do
    found = described_class.call(name: 'Легенда Плюс',
                                 city: 'Рязань',
                                 address: 'Рязань, ул. Интернациональная, д. 20, кв. 5')

    expect(found).to eq(legenda)
  end

  it 'не склеивает одноимённые ЖК из разных городов' do
    expect(described_class.call(name: 'Легенда', city: 'Москва')).to be_nil
  end

  it 'отдаёт nil, когда совпадения нет — это сигнал завести черновик' do
    expect(described_class.call(name: 'Небывалый', city: 'Рязань')).to be_nil
  end
end
```

- [ ] **Step 2: Убедиться, что спек падает**

Run: `bin/rb --db bundle exec rspec spec/services/zhk/matcher_spec.rb`
Expected: FAIL, `uninitialized constant Zhk::Matcher`

- [ ] **Step 3: Реализовать**

```ruby
# app/services/zhk/matcher.rb
# frozen_string_literal: true

module Zhk
  # Сопоставление находки службы сбора с записью справочника.
  #
  # Сравнение идёт в Ruby, а не в SQL, намеренно: справочник это десятки
  # строк на город, а нормализация («ЖК», кавычки, ё, регистр) в SQL
  # превратилась бы в нечитаемое выражение, которое ещё и индекс не берёт.
  module Matcher
    PREFIX_RX = /\A\s*(жк|жилой\s+комплекс)\s+/i
    JUNK_RX   = /[^[:alnum:]]+/

    module_function

    def call(name:, city:, address: nil)
      pool = ResidentialComplex.unscoped.not_deleted.in_city(city).to_a
      target = normalize(name)

      by_name = pool.find { |c| normalize(c.name) == target }
      return by_name if by_name

      return nil if address.blank?

      pool.find do |complex|
        Array(complex.address_patterns).compact_blank.any? do |pattern|
          address.downcase.include?(pattern.downcase)
        end
      end
    end

    # «ЖК «ЛЕГЕНДА»» и «Легенда» — одно и то же; «Голландия. Парковый
    # квартал» и «Голландия Парковый квартал» — тоже.
    def normalize(value)
      value.to_s.downcase.tr('ё', 'е').sub(PREFIX_RX, '').gsub(JUNK_RX, ' ').strip.squeeze(' ')
    end
  end
end
```

- [ ] **Step 4: Прогнать спек**

Run: `bin/rb --db bundle exec rspec spec/services/zhk/matcher_spec.rb`
Expected: PASS, 4 examples, 0 failures

- [ ] **Step 5: Линтер и коммит**

```bash
bin/rb bundle exec rubocop app/services/zhk/matcher.rb
git add app/services/zhk/matcher.rb spec/services/zhk/matcher_spec.rb
git commit -m "feat(zhk): сопоставление находки со справочником"
```

---

### Task 4: `Zhk::Ingest` — применение одного наблюдения

**Files:**
- Create: `app/services/zhk/ingest.rb`
- Create: `spec/fixtures/zhk/observation_example.json` — **общий контракт**
- Test: `spec/services/zhk/ingest_spec.rb`

**Interfaces:**
- Consumes: `Zhk::Matcher.call`, `Zhk::FactApplier.apply`, модели из Task 1.
- Produces: `Zhk::Ingest.call(payload) → Zhk::Ingest::Result(status:, complex_id:, filled:, discrepancies:)`, где `status ∈ %i[created updated duplicate invalid]`, `filled` — массив символов, `discrepancies` — массив строк с именами полей.

- [ ] **Step 1: Положить общий контракт**

```json
{
  "source": "erz",
  "url": "https://erzrf.ru/novostroyki/zhk-skobelev-564336001",
  "external_id": "erz:564336001",
  "fetched_at": "2026-09-07T05:00:00Z",
  "name": "Скобелев",
  "city": "Рязань",
  "fields": {
    "developer": "Единство",
    "built_to": 2022,
    "buildings_count": 4,
    "address": "Рязань, ул. Шереметьевская"
  },
  "price": { "kind": "from", "price_per_sqm": 65000, "rooms": null }
}
```

Этот файл читают обе стороны: Rails в спеке ниже, Python в своих тестах (Task 7). Менять его можно только вместе с обеими сторонами — в одном коммите.

- [ ] **Step 2: Написать падающий спек**

```ruby
# spec/services/zhk/ingest_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Zhk::Ingest do
  let(:payload) { JSON.parse(Rails.root.join('spec/fixtures/zhk/observation_example.json').read) }

  it 'заводит черновик, когда такого ЖК в справочнике нет' do
    result = described_class.call(payload)

    expect(result.status).to eq(:created)
    complex = ResidentialComplex.unscoped.find(result.complex_id)
    expect(complex.name).to eq('Скобелев')
    expect(complex.published).to be false
    expect(complex.developer).to eq('Единство')
  end

  it 'пишет провенанс на каждое присланное поле, а не только на заполненные' do
    create(:residential_complex, name: 'Скобелев', city: 'Рязань', developer: 'Правка редактора')

    described_class.call(payload)

    fact = ZhkFact.find_by(field: 'developer', source: 'erz')
    expect(fact.value).to eq('Единство')
    expect(fact.url).to eq(payload['url'])
  end

  it 'не переприменяет то же наблюдение — идемпотентность по digest' do
    described_class.call(payload)

    second = described_class.call(payload)

    expect(second.status).to eq(:duplicate)
    expect(ZhkObservation.count).to eq(1)
  end

  it 'поднимает расхождение, когда второй источник спорит с первым' do
    described_class.call(payload)

    other = payload.merge('source' => 'developer_site', 'external_id' => 'edinstvo:83',
                          'fields' => { 'developer' => 'Другой застройщик' })
    result = described_class.call(other)

    expect(result.discrepancies).to include('developer')
  end

  it 'записывает точку цены с пометкой, что это за цена' do
    described_class.call(payload)

    point = ZhkPricePoint.last
    expect(point.price_per_sqm).to eq(65_000)
    expect(point.kind_from?).to be true
  end

  it 'отвергает наблюдение без источника или имени' do
    expect(described_class.call(payload.except('name')).status).to eq(:invalid)
  end
end
```

- [ ] **Step 3: Убедиться, что спек падает**

Run: `bin/rb --db bundle exec rspec spec/services/zhk/ingest_spec.rb`
Expected: FAIL, `uninitialized constant Zhk::Ingest`

- [ ] **Step 4: Реализовать**

```ruby
# app/services/zhk/ingest.rb
# frozen_string_literal: true

module Zhk
  # Применение одного наблюдения от службы сбора. Здесь и только здесь
  # решается, что из присланного попадёт в справочник: служба сбора таких
  # решений не принимает и в базу не пишет.
  class Ingest
    Result = Struct.new(:status, :complex_id, :filled, :discrepancies, :error, keyword_init: true)

    REQUIRED = %w[source external_id name city].freeze

    def self.call(payload)
      new(payload).call
    end

    def initialize(payload)
      @payload = payload.deep_stringify_keys
    end

    def call
      missing = REQUIRED.select { |key| @payload[key].blank? }
      return Result.new(status: :invalid, error: "нет полей: #{missing.join(', ')}") if missing.any?
      return Result.new(status: :duplicate) if seen_before?

      complex = matched || build_draft
      filled = FactApplier.apply(complex, fields.symbolize_keys)
      was_new = complex.new_record?
      complex.save!

      record_observation
      record_facts(complex)
      record_price(complex)

      Result.new(status: was_new ? :created : :updated, complex_id: complex.id,
                 filled: filled, discrepancies: discrepancies_for(complex))
    end

    private

    def fields
      # Служба может прислать что угодно; в справочник попадает только
      # то, что разрешено белым списком.
      @payload.fetch('fields', {}).slice(*FactApplier::FILLABLE.map(&:to_s))
    end

    def digest
      @digest ||= Digest::SHA256.hexdigest(@payload.except('fetched_at').to_json)
    end

    def seen_before?
      ZhkObservation.exists?(source: @payload['source'],
                             external_id: @payload['external_id'],
                             digest: digest)
    end

    def matched
      Matcher.call(name: @payload['name'], city: @payload['city'],
                   address: fields['address'])
    end

    def build_draft
      ResidentialComplex.new(name: @payload['name'], city: @payload['city'], published: false)
    end

    def observed_at
      @observed_at ||= Time.zone.parse(@payload['fetched_at'].to_s) || Time.current
    end

    def record_observation
      ZhkObservation.create!(source: @payload['source'], external_id: @payload['external_id'],
                            url: @payload['url'], fetched_at: observed_at,
                            payload: @payload, digest: digest)
    end

    # Провенанс пишется на ВСЁ присланное, а не только на то, что попало в
    # колонку: иначе расхождение между источниками негде увидеть.
    def record_facts(complex)
      fields.each do |field, value|
        fact = ZhkFact.find_or_initialize_by(residential_complex: complex, field: field,
                                             source: @payload['source'])
        fact.update!(value: value.to_s, url: @payload['url'], observed_at: observed_at)
      end
    end

    def record_price(complex)
      price = @payload['price']
      return if price.blank? || price['price_per_sqm'].blank?

      ZhkPricePoint.create!(residential_complex: complex, source: @payload['source'],
                            observed_at: observed_at, price_per_sqm: price['price_per_sqm'],
                            kind: price.fetch('kind', 'from'), rooms: price['rooms'],
                            url: @payload['url'])
    end

    def discrepancies_for(complex)
      Discrepancies.fields_for(complex)
    end
  end
end
```

- [ ] **Step 5: Прогнать спек**

Run: `bin/rb --db bundle exec rspec spec/services/zhk/ingest_spec.rb`
Expected: PASS, 6 examples, 0 failures. Task 5 зависит от `Zhk::Discrepancies.fields_for` — если задачи идут по порядку, сначала выполните Task 5 (он маленький) либо временно верните `[]`.

- [ ] **Step 6: Линтер и коммит**

```bash
bin/rb bundle exec rubocop app/services/zhk/ingest.rb
git add app/services/zhk/ingest.rb spec/services/zhk/ingest_spec.rb spec/fixtures/zhk/observation_example.json
git commit -m "feat(zhk): применение наблюдения — черновик, провенанс, цена"
```

---

### Task 5: `Zhk::Discrepancies` — расхождения запросом

**Files:**
- Create: `app/services/zhk/discrepancies.rb`
- Test: `spec/services/zhk/discrepancies_spec.rb`

**Interfaces:**
- Produces: `Zhk::Discrepancies.fields_for(complex) → Array<String>` (имена спорных полей); `Zhk::Discrepancies.all → Array<Hash{complex:, field:, values: Array<Hash{value:, source:, url:, observed_at:}>}>`.

- [ ] **Step 1: Написать падающий спек**

```ruby
# spec/services/zhk/discrepancies_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Zhk::Discrepancies do
  let(:complex) { create(:residential_complex) }

  def fact(field, value, source)
    ZhkFact.create!(residential_complex: complex, field: field, value: value,
                    source: source, observed_at: Time.current)
  end

  it 'молчит, когда источники согласны' do
    fact('developer', 'Единство', 'erz')
    fact('developer', 'Единство', 'developer_site')

    expect(described_class.fields_for(complex)).to be_empty
  end

  it 'называет поле, по которому источники спорят' do
    fact('developer', 'Единство', 'erz')
    fact('developer', 'Северная компания', 'developer_site')

    expect(described_class.fields_for(complex)).to eq(['developer'])
  end

  it 'отдаёт для экрана обе версии со ссылками' do
    fact('built_to', '2022', 'erz')
    fact('built_to', '2023', 'developer_site')

    row = described_class.all.first
    expect(row[:field]).to eq('built_to')
    expect(row[:values].map { |v| v[:value] }).to match_array(%w[2022 2023])
  end
end
```

- [ ] **Step 2: Убедиться, что спек падает**

Run: `bin/rb --db bundle exec rspec spec/services/zhk/discrepancies_spec.rb`
Expected: FAIL, `uninitialized constant Zhk::Discrepancies`

- [ ] **Step 3: Реализовать**

```ruby
# app/services/zhk/discrepancies.rb
# frozen_string_literal: true

module Zhk
  # Расхождение — это запрос к фактам, а не хранимая сущность: отдельная
  # таблица держала бы производное состояние, которое разъезжается первым.
  module Discrepancies
    module_function

    # @return [Array<String>] поля этого ЖК, по которым источники спорят
    def fields_for(complex)
      ZhkFact.where(residential_complex_id: complex.id)
             .group(:field)
             .having('COUNT(DISTINCT value) > 1')
             .pluck(:field)
    end

    # @return [Array<Hash>] для экрана админки
    def all
      conflicting = ZhkFact.group(:residential_complex_id, :field)
                           .having('COUNT(DISTINCT value) > 1')
                           .pluck(:residential_complex_id, :field)
      return [] if conflicting.empty?

      facts = ZhkFact.where(residential_complex_id: conflicting.map(&:first))
                     .includes(:residential_complex)
                     .group_by { |f| [f.residential_complex_id, f.field] }

      conflicting.map do |key|
        rows = facts.fetch(key, [])
        { complex: rows.first&.residential_complex,
          field: key.last,
          values: rows.map do |f|
            { value: f.value, source: f.source, url: f.url, observed_at: f.observed_at }
          end }
      end
    end
  end
end
```

- [ ] **Step 4: Прогнать спек**

Run: `bin/rb --db bundle exec rspec spec/services/zhk/discrepancies_spec.rb`
Expected: PASS, 3 examples, 0 failures

- [ ] **Step 5: Линтер и коммит**

```bash
bin/rb bundle exec rubocop app/services/zhk/discrepancies.rb
git add app/services/zhk/discrepancies.rb spec/services/zhk/discrepancies_spec.rb
git commit -m "feat(zhk): расхождения источников как запрос к фактам"
```

---

### Task 6: Вебхук приёма батча

**Files:**
- Create: `app/controllers/webhooks/zhk_ingest_controller.rb`
- Modify: `config/routes.rb` (в `namespace :webhooks`, рядом с `post 'news_ingest'` — строка ~800)
- Test: `spec/requests/webhooks/zhk_ingest_controller_spec.rb`

**Interfaces:**
- Consumes: `Zhk::Ingest.call`.
- Produces: `POST /webhooks/zhk_ingest` — тело `{ "observations": [ ...контракт... ] }`, ответ `{ "results": [ { "external_id": ..., "status": ..., "complex_id": ..., "discrepancies": [...] } ] }`. Токен — `ENV['ZHK_INGEST_TOKEN']`, заголовок `Authorization: Bearer <token>`. Больше `MAX_BATCH = 50` наблюдений — 422.

- [ ] **Step 1: Написать падающий спек**

```ruby
# spec/requests/webhooks/zhk_ingest_controller_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'POST /webhooks/zhk_ingest', type: :request do
  let(:token) { 'test-zhk-ingest-token' }
  let(:observation) { JSON.parse(Rails.root.join('spec/fixtures/zhk/observation_example.json').read) }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'CONTENT_TYPE' => 'application/json' } }

  around do |ex|
    original = ENV['ZHK_INGEST_TOKEN']
    ENV['ZHK_INGEST_TOKEN'] = token
    ex.run
    ENV['ZHK_INGEST_TOKEN'] = original
  end

  it '401 без токена' do
    post '/webhooks/zhk_ingest', params: { observations: [observation] }.to_json,
                                 headers: { 'CONTENT_TYPE' => 'application/json' }

    expect(response).to have_http_status(:unauthorized)
  end

  it 'принимает батч и отвечает построчным отчётом' do
    post '/webhooks/zhk_ingest', params: { observations: [observation] }.to_json, headers: headers

    expect(response).to have_http_status(:ok)
    row = response.parsed_body['results'].first
    expect(row['status']).to eq('created')
    expect(row['external_id']).to eq('erz:564336001')
  end

  it 'повторная отправка того же батча ничего не создаёт' do
    post '/webhooks/zhk_ingest', params: { observations: [observation] }.to_json, headers: headers
    post '/webhooks/zhk_ingest', params: { observations: [observation] }.to_json, headers: headers

    expect(response.parsed_body['results'].first['status']).to eq('duplicate')
    expect(ResidentialComplex.unscoped.count).to eq(1)
  end

  it 'отбивает батч длиннее лимита — служба обязана резать сама' do
    post '/webhooks/zhk_ingest',
         params: { observations: Array.new(51) { observation } }.to_json, headers: headers

    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'плохое наблюдение не роняет остальные' do
    post '/webhooks/zhk_ingest',
         params: { observations: [observation.except('name'), observation] }.to_json, headers: headers

    statuses = response.parsed_body['results'].map { |r| r['status'] }
    expect(statuses).to eq(%w[invalid created])
  end
end
```

- [ ] **Step 2: Убедиться, что спек падает**

Run: `bin/rb --db bundle exec rspec spec/requests/webhooks/zhk_ingest_controller_spec.rb`
Expected: FAIL, роут не найден (`ActionController::RoutingError`)

- [ ] **Step 3: Добавить роут**

В `config/routes.rb`, в `namespace :webhooks` сразу после строки `post 'news_ingest', to: 'news_ingest#create', as: :news_ingest`:

```ruby
    # Служба сбора данных о ЖК (services/zhk-registry) шлёт сюда батчи
    # наблюдений. Решение, что применить, принимает Rails — см. Zhk::Ingest.
    post 'zhk_ingest', to: 'zhk_ingest#create', as: :zhk_ingest
```

- [ ] **Step 4: Реализовать контроллер**

```ruby
# app/controllers/webhooks/zhk_ingest_controller.rb
# frozen_string_literal: true

module Webhooks
  # Приём наблюдений от services/zhk-registry. Аутентификация bearer-токеном
  # по образцу NewsIngestController.
  #
  # Каждое наблюдение применяется независимо: одно битое не роняет батч,
  # частичный результат — штатный исход, а не авария.
  class ZhkIngestController < ApplicationController
    skip_before_action :verify_authenticity_token, raise: false
    before_action :authenticate_bearer!

    MAX_BATCH = 50

    def create
      observations = params.require(:observations)
      if observations.size > MAX_BATCH
        return render json: { error: 'batch_too_large', max: MAX_BATCH },
                      status: :unprocessable_entity
      end

      results = observations.map { |raw| apply(raw) }
      render json: { results: results }
    end

    private

    def apply(raw)
      payload = raw.to_unsafe_h.deep_stringify_keys
      result = Zhk::Ingest.call(payload)

      { external_id: payload['external_id'], status: result.status,
        complex_id: result.complex_id, filled: result.filled,
        discrepancies: result.discrepancies, error: result.error }.compact
    end

    def authenticate_bearer!
      configured = ENV['ZHK_INGEST_TOKEN'].to_s
      if configured.empty?
        Rails.logger.warn('[ZhkIngest] ZHK_INGEST_TOKEN не задан — отклоняем всё')
        head :forbidden and return
      end

      header = request.headers['Authorization'].to_s
      provided = header.start_with?('Bearer ') ? header.split(' ', 2).last.to_s : header
      head :unauthorized unless ActiveSupport::SecurityUtils.secure_compare(provided, configured)
    end
  end
end
```

- [ ] **Step 5: Прогнать спек**

Run: `bin/rb --db bundle exec rspec spec/requests/webhooks/zhk_ingest_controller_spec.rb`
Expected: PASS, 5 examples, 0 failures

- [ ] **Step 6: Линтер и коммит**

```bash
bin/rb bundle exec rubocop app/controllers/webhooks/zhk_ingest_controller.rb config/routes.rb
git add app/controllers/webhooks/zhk_ingest_controller.rb config/routes.rb spec/requests/webhooks/zhk_ingest_controller_spec.rb
git commit -m "feat(zhk): вебхук приёма наблюдений от службы сбора"
```

---

### Task 7: Экран расхождений в админке

**Files:**
- Create: `app/controllers/admin/zhk_discrepancies_controller.rb`
- Create: `app/views/admin/zhk_discrepancies/index.html.erb`
- Modify: `config/routes.rb` (в `namespace :admin`, рядом с `resources :residential_complexes` — строка ~672)
- Test: `spec/requests/admin/zhk_discrepancies_spec.rb`

**Interfaces:**
- Consumes: `Zhk::Discrepancies.all`, concern `AdminTokenAuth`.
- Produces: `GET /admin/zhk_discrepancies`.

- [ ] **Step 1: Написать падающий спек**

```ruby
# spec/requests/admin/zhk_discrepancies_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'GET /admin/zhk_discrepancies', type: :request do
  include_context 'с админ-токеном'

  let!(:complex) { create(:residential_complex, name: 'Скобелев') }

  before do
    ZhkFact.create!(residential_complex: complex, field: 'developer', value: 'Единство',
                    source: 'erz', observed_at: Time.current)
    ZhkFact.create!(residential_complex: complex, field: 'developer', value: 'Северная компания',
                    source: 'developer_site', observed_at: Time.current)
  end

  it 'без токена не пускает' do
    get '/admin/zhk_discrepancies'

    expect(response).to have_http_status(:found)
  end

  it 'показывает обе версии и их источники' do
    admin_get '/admin/zhk_discrepancies'

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Скобелев').and include('Единство').and include('Северная компания')
  end
end
```

Аутентификация в спеке — через существующий shared context `'с админ-токеном'` из `spec/support/admin_auth_helpers.rb` (Фаза 2 A2): он подменяет `ENV['ADMIN_TOKEN']` на время примера и даёт `admin_get`/`admin_post`/`admin_patch`, которые сами дописывают токен в параметры. Голого хелпера `admin_token` в проекте нет — контекст раздаётся целиком именно чтобы спек не получил молча редирект вместо 200.

- [ ] **Step 2: Убедиться, что спек падает**

Run: `bin/rb --db bundle exec rspec spec/requests/admin/zhk_discrepancies_spec.rb`
Expected: FAIL, роут не найден

- [ ] **Step 3: Добавить роут**

В `config/routes.rb`, в `namespace :admin` сразу после блока `resources :residential_complexes do ... end`:

```ruby
    # Где источники спорят между собой — очередь на проверку редактором.
    get 'zhk_discrepancies', to: 'zhk_discrepancies#index', as: :zhk_discrepancies
```

- [ ] **Step 4: Реализовать контроллер и вьюху**

```ruby
# app/controllers/admin/zhk_discrepancies_controller.rb
# frozen_string_literal: true

module Admin
  # Поля, по которым источники службы сбора противоречат друг другу.
  # Экран только показывает: правку вносит редактор в карточке ЖК, потому
  # что решение «кто прав» человеческое, а не автоматическое.
  class ZhkDiscrepanciesController < ApplicationController
    include AdminTokenAuth
    layout 'application'

    def index
      @rows = Zhk::Discrepancies.all
    end
  end
end
```

```erb
<%# app/views/admin/zhk_discrepancies/index.html.erb %>
<div class="mx-auto max-w-5xl px-4 py-8">
  <h1 class="text-2xl font-semibold mb-2">Расхождения источников</h1>
  <p class="text-sm text-gray-600 mb-6">
    Поля, по которым источники не согласны между собой. Пока расхождение не
    разрешено, поле в карточке остаётся пустым: неверная фактура на странице
    ЖК хуже отсутствующей.
  </p>

  <% if @rows.empty? %>
    <p class="text-gray-500">Расхождений нет.</p>
  <% else %>
    <% @rows.each do |row| %>
      <div class="mb-6 rounded border border-gray-200 p-4">
        <div class="flex items-baseline justify-between mb-3">
          <h2 class="font-medium">
            <%= link_to row[:complex].display_name,
                        edit_admin_residential_complex_path(row[:complex], token: params[:token]),
                        class: 'text-blue-700 hover:underline' %>
            <span class="text-gray-500">— <%= row[:field] %></span>
          </h2>
        </div>
        <table class="w-full text-sm">
          <tbody>
            <% row[:values].each do |value| %>
              <tr class="border-t border-gray-100">
                <td class="py-2 font-medium"><%= value[:value] %></td>
                <td class="py-2 text-gray-600"><%= value[:source] %></td>
                <td class="py-2">
                  <% if value[:url].present? %>
                    <%= link_to 'источник', value[:url], target: '_blank', rel: 'noopener',
                                class: 'text-blue-700 hover:underline' %>
                  <% end %>
                </td>
                <td class="py-2 text-gray-500"><%= l(value[:observed_at].to_date, format: '%d.%m.%y') %></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    <% end %>
  <% end %>
</div>
```

- [ ] **Step 5: Прогнать спек**

Run: `bin/rb --db bundle exec rspec spec/requests/admin/zhk_discrepancies_spec.rb`
Expected: PASS, 2 examples, 0 failures

- [ ] **Step 6: Линтер и коммит**

```bash
bin/rb bundle exec rubocop app/controllers/admin/zhk_discrepancies_controller.rb config/routes.rb
git add app/controllers/admin/zhk_discrepancies_controller.rb app/views/admin/zhk_discrepancies config/routes.rb spec/requests/admin/zhk_discrepancies_spec.rb
git commit -m "feat(zhk): экран расхождений источников в админке"
```

---

### Task 8: Каркас питоновской службы и контракт

**Files:**
- Create: `services/zhk-registry/observation.py`, `client.py`, `requirements.txt`, `.env.example`, `README.md`, `CLAUDE.md`
- Create: `services/zhk-registry/tests/__init__.py`, `tests/test_observation.py`
- Test: `python3 -m unittest discover -v` из каталога службы

**Interfaces:**
- Produces: `Observation` (pydantic) с полями `source, url, external_id, fetched_at, name, city, fields, price` и методом `to_payload() -> dict`; `IngestClient(base_url, token).send(observations: list[Observation]) -> list[dict]` — режет батч по 50 и шлёт `POST /webhooks/zhk_ingest`.

- [ ] **Step 1: Написать падающий тест**

```python
# services/zhk-registry/tests/test_observation.py
"""Контракт наблюдения. Образец общий с Rails — если тест упал после правки
образца, значит контракт разъехался, и чинить надо обе стороны сразу.

Запуск:
    cd services/zhk-registry && python3 -m unittest discover -v
"""

import json
import os
import unittest

from observation import Observation

CONTRACT = os.path.join(os.path.dirname(__file__), "..", "..", "..",
                        "spec", "fixtures", "zhk", "observation_example.json")


class TestObservationContract(unittest.TestCase):
    def test_parses_shared_contract_fixture(self):
        with open(CONTRACT, encoding="utf-8") as fh:
            raw = json.load(fh)

        obs = Observation(**raw)

        self.assertEqual(obs.source, "erz")
        self.assertEqual(obs.name, "Скобелев")
        self.assertEqual(obs.fields["developer"], "Единство")
        self.assertEqual(obs.price.price_per_sqm, 65000)

    def test_roundtrip_keeps_shape(self):
        with open(CONTRACT, encoding="utf-8") as fh:
            raw = json.load(fh)

        self.assertEqual(Observation(**raw).to_payload(), raw)

    def test_rejects_observation_without_source(self):
        from pydantic import ValidationError

        with self.assertRaises(ValidationError):
            Observation(external_id="x", name="Скобелев", city="Рязань",
                        fetched_at="2026-09-07T05:00:00Z", fields={})
```

- [ ] **Step 2: Убедиться, что тест падает**

Run: `cd services/zhk-registry && python3 -m unittest discover -v`
Expected: FAIL, `ModuleNotFoundError: No module named 'observation'`

- [ ] **Step 3: Реализовать модель и клиента**

```python
# services/zhk-registry/observation.py
"""Наблюдение — единица обмена со стороной Rails.

Служба НЕ решает, что из наблюдения попадёт в справочник: это делает
Zhk::Ingest. Здесь только форма и валидация формы.
"""

from typing import Any, Optional

from pydantic import BaseModel, Field


class Price(BaseModel):
    # from — цена «от» с сайта застройщика, median — медиана по лотам у
    # агрегатора. Величины разные; сравнивать можно только внутри одного
    # источника И одного kind.
    kind: str = "from"
    price_per_sqm: int
    rooms: Optional[int] = None


class Observation(BaseModel):
    source: str
    external_id: str
    name: str
    city: str
    fetched_at: str
    url: Optional[str] = None
    fields: dict[str, Any] = Field(default_factory=dict)
    price: Optional[Price] = None

    def to_payload(self) -> dict:
        return self.model_dump(exclude_none=False)
```

```python
# services/zhk-registry/client.py
"""Отправка наблюдений в Rails. Единственный способ службы что-либо
записать: прямого доступа к базе у неё нет и быть не должно.
"""

import logging
from typing import Iterable

import requests

from observation import Observation

MAX_BATCH = 50
TIMEOUT = 30

log = logging.getLogger(__name__)


class IngestClient:
    def __init__(self, base_url: str, token: str):
        self.base_url = base_url.rstrip("/")
        self.token = token

    def send(self, observations: Iterable[Observation]) -> list[dict]:
        results: list[dict] = []
        batch: list[Observation] = []

        for obs in observations:
            batch.append(obs)
            if len(batch) == MAX_BATCH:
                results.extend(self._post(batch))
                batch = []

        if batch:
            results.extend(self._post(batch))

        return results

    def _post(self, batch: list[Observation]) -> list[dict]:
        response = requests.post(
            f"{self.base_url}/webhooks/zhk_ingest",
            json={"observations": [o.to_payload() for o in batch]},
            headers={"Authorization": f"Bearer {self.token}"},
            timeout=TIMEOUT,
        )
        response.raise_for_status()
        rows = response.json().get("results", [])
        for row in rows:
            if row.get("status") == "invalid":
                log.warning("наблюдение отвергнуто: %s — %s", row.get("external_id"), row.get("error"))
        return rows
```

```
# services/zhk-registry/requirements.txt
beautifulsoup4==4.13.6
pydantic==2.13.3
python-dotenv==1.2.2
requests==2.33.1
```

```
# services/zhk-registry/.env.example
# Куда отправлять наблюдения и с каким токеном (тот же, что ZHK_INGEST_TOKEN в Rails).
VICTORY_BASE_URL=https://victory62.org
ZHK_INGEST_TOKEN=

# Контакт в User-Agent — обход обязан быть представленным.
CRAWLER_CONTACT=info@victory62.org
```

`README.md` и `CLAUDE.md` — по образцу `services/urgent-news-collector`: что делает, как запускается, что где лежит, чего делать нельзя (писать в БД, импортировать соседние службы, менять контракт в одиночку).

- [ ] **Step 4: Прогнать тесты**

Run: `cd services/zhk-registry && python3 -m unittest discover -v`
Expected: PASS, 3 теста

- [ ] **Step 5: Коммит**

```bash
git add services/zhk-registry
git commit -m "feat(zhk-registry): каркас службы и общий контракт наблюдения"
```

---

### Task 9: Адаптер ЕРЗ.РФ — обнаружение и обогащение

**Files:**
- Create: `services/zhk-registry/sources/__init__.py`, `sources/base.py`, `sources/erz.py`
- Create: `services/zhk-registry/tests/fixtures/erz_list.html`, `tests/fixtures/erz_card.html`, `tests/test_erz.py`

**Interfaces:**
- Consumes: `Observation` из Task 8.
- Produces: `sources.base.Source` (протокол: `name: str`, `weight: int`, `discover() -> list[dict]`, `enrich(ref: dict) -> Observation | None`); `sources.erz.ErzSource(session, contact)` с `name = 'erz'`, `weight = 2`.

- [ ] **Step 1: Снять фикстуры**

```bash
cd services/zhk-registry/tests/fixtures
curl -sA "victory62-registry (info@victory62.org)" \
  'https://erzrf.ru/novostroyki/zhk-skobelev-564336001' -o erz_card.html
# Список ЖК региона. URL проверить перед снятием — открыть в браузере и
# убедиться, что это каталог Рязанской области, а не редирект на общий:
curl -sA "victory62-registry (info@victory62.org)" \
  'https://erzrf.ru/novostroyki/ryazanskaya-oblast' -o erz_list.html
grep -c 'novostroyki/zhk-' erz_list.html   # 0 — значит URL или разметка другие
```

Фикстуры коммитятся вместе с тестами: сети в тестах нет вообще, и редизайн чужого сайта чинится обновлением фикстуры, а не отладкой в проде.

- [ ] **Step 2: Написать падающий тест**

```python
# services/zhk-registry/tests/test_erz.py
"""Разбор ЕРЗ на зафиксированной странице. Сети здесь нет намеренно."""

import os
import unittest

from sources.erz import ErzSource

FIXTURES = os.path.join(os.path.dirname(__file__), "fixtures")


def fixture(name: str) -> str:
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as fh:
        return fh.read()


class TestErzCard(unittest.TestCase):
    def test_extracts_facts_from_card(self):
        obs = ErzSource(session=None, contact="test@example.com").parse_card(
            fixture("erz_card.html"),
            url="https://erzrf.ru/novostroyki/zhk-skobelev-564336001",
        )

        self.assertEqual(obs.source, "erz")
        self.assertEqual(obs.name, "Скобелев")
        self.assertEqual(obs.city, "Рязань")
        self.assertEqual(obs.fields["developer"], "Единство")

    def test_missing_field_is_absent_not_guessed(self):
        obs = ErzSource(session=None, contact="test@example.com").parse_card(
            fixture("erz_card.html"),
            url="https://erzrf.ru/novostroyki/zhk-skobelev-564336001",
        )

        # Чего на странице нет — того нет в наблюдении. Пустая строка или
        # «н/д» в fields превратились бы на стороне Rails в факт.
        for key, value in obs.fields.items():
            self.assertNotIn(value, ("", "н/д", "—"), key)
```

- [ ] **Step 3: Убедиться, что тест падает**

Run: `cd services/zhk-registry && python3 -m unittest discover -v`
Expected: FAIL, `ModuleNotFoundError: No module named 'sources'`

- [ ] **Step 4: Реализовать**

```python
# services/zhk-registry/sources/base.py
"""Общее для адаптеров источников.

Вес источника живёт ЗДЕСЬ, в конфиге адаптера, и в базу не попадает
никогда: это свойство источника, а не строки данных. Надстройки (черновик
текста, досье) получат вес в промпт как контекст.
"""

import time
from typing import Protocol

from observation import Observation

# Вежливость обхода не факультативна: пауза между запросами и
# представленный User-Agent.
DELAY_SECONDS = 12


class Source(Protocol):
    name: str
    weight: int

    def discover(self) -> list[dict]: ...

    def enrich(self, ref: dict) -> Observation | None: ...


def polite_get(session, url: str, contact: str) -> str:
    time.sleep(DELAY_SECONDS)
    response = session.get(
        url,
        headers={"User-Agent": f"victory62-registry ({contact})"},
        timeout=30,
    )
    response.raise_for_status()
    return response.text
```

```python
# services/zhk-registry/sources/erz.py
"""ЕРЗ.РФ — обнаружение новых ЖК и фактура средней достоверности.

Роль в реестре: находить комплексы, которых нет в справочнике. Первичным
источником по фактам считается сайт застройщика (вес выше).
"""

import re

from bs4 import BeautifulSoup

from observation import Observation
from sources.base import polite_get

REGION_URL = "https://erzrf.ru/novostroyki/ryazanskaya-oblast"
CITY = "Рязань"


class ErzSource:
    name = "erz"
    weight = 2

    def __init__(self, session, contact: str):
        self.session = session
        self.contact = contact

    def discover(self) -> list[dict]:
        html = polite_get(self.session, REGION_URL, self.contact)
        soup = BeautifulSoup(html, "html.parser")

        refs = []
        for link in soup.select("a[href*='/novostroyki/zhk-']"):
            href = link.get("href", "")
            match = re.search(r"/novostroyki/(zhk-[\w-]+?-(\d+))", href)
            if not match:
                continue
            refs.append({
                "url": href if href.startswith("http") else f"https://erzrf.ru{href}",
                "external_id": f"erz:{match.group(2)}",
                "name": link.get_text(strip=True),
            })
        return refs

    def enrich(self, ref: dict) -> Observation | None:
        html = polite_get(self.session, ref["url"], self.contact)
        return self.parse_card(html, url=ref["url"])

    def parse_card(self, html: str, url: str) -> Observation:
        soup = BeautifulSoup(html, "html.parser")
        fields = {}

        developer = self._labelled(soup, "Застройщик")
        if developer:
            fields["developer"] = developer

        floors = self._labelled(soup, "Этажность")
        if floors:
            numbers = [int(n) for n in re.findall(r"\d+", floors)]
            if numbers:
                fields["floors_min"] = min(numbers)
                fields["floors_max"] = max(numbers)

        return Observation(
            source=self.name,
            external_id=self._external_id(url),
            url=url,
            name=self._title(soup),
            city=CITY,
            fetched_at=self._now(),
            fields=fields,
        )

    # --- вспомогательное -------------------------------------------------

    def _labelled(self, soup, label: str) -> str | None:
        """Значение рядом с подписью. Пустое или «н/д» — это отсутствие
        факта, а не факт: на стороне Rails оно стало бы записью в провенансе.
        """
        node = soup.find(string=re.compile(rf"^\s*{label}\s*:?\s*$"))
        if not node:
            return None
        value = node.find_next(string=True)
        value = (value or "").strip()
        return value if value and value not in {"н/д", "—", "-"} else None

    def _title(self, soup) -> str:
        heading = soup.find("h1")
        text = heading.get_text(strip=True) if heading else ""
        return re.sub(r"^\s*(ЖК|Жилой комплекс)\s+", "", text).strip('«»" ')

    def _external_id(self, url: str) -> str:
        match = re.search(r"-(\d+)\s*$", url)
        return f"erz:{match.group(1)}" if match else f"erz:{url}"

    def _now(self) -> str:
        from datetime import datetime, timezone
        return datetime.now(timezone.utc).isoformat()
```

Селекторы в `_labelled` и `discover` подгоняются под фактическую фикстуру — тест из шага 2 и есть критерий готовности.

- [ ] **Step 5: Прогнать тесты**

Run: `cd services/zhk-registry && python3 -m unittest discover -v`
Expected: PASS, 5 тестов

- [ ] **Step 6: Коммит**

```bash
git add services/zhk-registry/sources services/zhk-registry/tests
git commit -m "feat(zhk-registry): адаптер ЕРЗ — обнаружение и разбор карточки"
```

---

### Task 10: Адаптер сайта застройщика (Единство)

**Files:**
- Create: `services/zhk-registry/sources/edinstvo.py`
- Create: `services/zhk-registry/tests/fixtures/edinstvo_card.html`, `tests/test_edinstvo.py`

**Interfaces:**
- Produces: `sources.edinstvo.EdinstvoSource(session, contact)` с `name = 'developer_site'`, `weight = 3`, тем же протоколом `Source`.

Единство выбрано первым, потому что на нём висит семь из двенадцати засеянных ЖК — это самая быстрая проверка того, что связка работает от источника до карточки в админке.

- [ ] **Step 1: Снять фикстуру**

```bash
cd services/zhk-registry/tests/fixtures
curl -sA "victory62-registry (info@victory62.org)" 'https://edinstvo62.ru/building/83' -o edinstvo_card.html
```

- [ ] **Step 2: Написать падающий тест**

```python
# services/zhk-registry/tests/test_edinstvo.py
"""Разбор карточки застройщика на зафиксированной странице."""

import os
import unittest

from sources.edinstvo import EdinstvoSource

FIXTURES = os.path.join(os.path.dirname(__file__), "fixtures")


class TestEdinstvoCard(unittest.TestCase):
    def setUp(self):
        with open(os.path.join(FIXTURES, "edinstvo_card.html"), encoding="utf-8") as fh:
            self.html = fh.read()
        self.source = EdinstvoSource(session=None, contact="test@example.com")

    def test_developer_is_hardcoded_not_scraped(self):
        # На своём сайте застройщик себя не подписывает — имя известно из
        # того, чей это сайт, и выдумывать его разбором не нужно.
        obs = self.source.parse_card(self.html, url="https://edinstvo62.ru/building/83")

        self.assertEqual(obs.fields["developer"], "Единство")
        self.assertEqual(obs.source, "developer_site")

    def test_price_point_is_marked_as_from(self):
        obs = self.source.parse_card(self.html, url="https://edinstvo62.ru/building/83")

        if obs.price:
            self.assertEqual(obs.price.kind, "from")
            self.assertGreater(obs.price.price_per_sqm, 10000)
```

- [ ] **Step 3: Убедиться, что тест падает**

Run: `cd services/zhk-registry && python3 -m unittest discover -v`
Expected: FAIL, `No module named 'sources.edinstvo'`

- [ ] **Step 4: Реализовать**

```python
# services/zhk-registry/sources/edinstvo.py
"""ГК «Единство» — первичный источник по своим комплексам.

Вес выше, чем у агрегатора: застройщик знает про свой дом больше, чем
каталог. На нём висит семь из двенадцати засеянных ЖК.
"""

import re
from datetime import datetime, timezone

from bs4 import BeautifulSoup

from observation import Observation
from sources.base import polite_get

LIST_URL = "https://edinstvo62.ru/buildings"
DEVELOPER = "Единство"
CITY = "Рязань"


class EdinstvoSource:
    name = "developer_site"
    weight = 3

    def __init__(self, session, contact: str):
        self.session = session
        self.contact = contact

    def discover(self) -> list[dict]:
        html = polite_get(self.session, LIST_URL, self.contact)
        soup = BeautifulSoup(html, "html.parser")

        refs = []
        for link in soup.select("a[href*='/building/']"):
            href = link.get("href", "")
            match = re.search(r"/building/(\d+)", href)
            if not match:
                continue
            refs.append({
                "url": href if href.startswith("http") else f"https://edinstvo62.ru{href}",
                "external_id": f"edinstvo:{match.group(1)}",
                "name": link.get_text(strip=True),
            })
        return refs

    def enrich(self, ref: dict) -> Observation | None:
        html = polite_get(self.session, ref["url"], self.contact)
        return self.parse_card(html, url=ref["url"])

    def parse_card(self, html: str, url: str) -> Observation:
        soup = BeautifulSoup(html, "html.parser")
        heading = soup.find("h1")
        name = re.sub(r"^\s*ЖК\s+", "", heading.get_text(strip=True) if heading else "").strip('«»" ')

        price = None
        match = re.search(r"от\s*([\d\s]{4,})\s*(?:₽|руб)[^\n]{0,20}м", soup.get_text(" ", strip=True))
        if match:
            price = {"kind": "from", "price_per_sqm": int(re.sub(r"\D", "", match.group(1)))}

        match = re.search(r"/building/(\d+)", url)
        return Observation(
            source=self.name,
            external_id=f"edinstvo:{match.group(1)}" if match else f"edinstvo:{url}",
            url=url,
            name=name,
            city=CITY,
            fetched_at=datetime.now(timezone.utc).isoformat(),
            fields={"developer": DEVELOPER},
            price=price,
        )
```

- [ ] **Step 5: Прогнать тесты**

Run: `cd services/zhk-registry && python3 -m unittest discover -v`
Expected: PASS, 7 тестов

- [ ] **Step 6: Коммит**

```bash
git add services/zhk-registry/sources/edinstvo.py services/zhk-registry/tests
git commit -m "feat(zhk-registry): адаптер сайта застройщика Единство"
```

---

### Task 11: Оркестратор, сводка прогона и крон

**Files:**
- Create: `services/zhk-registry/run.py`, `services/zhk-registry/crontab.example`
- Create: `app/services/zhk/run_summary.rb`
- Modify: `app/controllers/webhooks/zhk_ingest_controller.rb` (+действие `summary`), `config/routes.rb`
- Test: `services/zhk-registry/tests/test_run.py`, `spec/services/zhk/run_summary_spec.rb`

**Interfaces:**
- Consumes: `IngestClient.send`, адаптеры из Task 9-10, `Telegram::Client#send_message(text, chat_id:)`.
- Produces: `run.py` (точка входа крона); `POST /webhooks/zhk_ingest/summary` — тело `{ "counts": { "erz": 70, "developer_site": 12 } }`; `Zhk::RunSummary.call(counts) → String` (текст сводки) и `Zhk::RunSummary.silent_sources(counts) → Array<String>`.

- [ ] **Step 1: Написать падающий спек детектора молчащего источника**

```ruby
# spec/services/zhk/run_summary_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Zhk::RunSummary do
  def observation(source, days_ago)
    ZhkObservation.create!(source: source, external_id: "#{source}:#{SecureRandom.hex(4)}",
                           fetched_at: days_ago.days.ago, payload: {},
                           digest: SecureRandom.hex(32))
  end

  it 'называет источник молчащим, когда он отдал кратно меньше обычного' do
    5.times { observation('erz', 9) }

    expect(described_class.silent_sources('erz' => 1)).to include('erz')
  end

  it 'молчит, когда объём в норме' do
    5.times { observation('erz', 9) }

    expect(described_class.silent_sources('erz' => 5)).to be_empty
  end

  it 'не считает молчащим источник, который раньше не появлялся' do
    expect(described_class.silent_sources('newcomer' => 1)).to be_empty
  end
end
```

- [ ] **Step 2: Убедиться, что спек падает**

Run: `bin/rb --db bundle exec rspec spec/services/zhk/run_summary_spec.rb`
Expected: FAIL, `uninitialized constant Zhk::RunSummary`

- [ ] **Step 3: Реализовать сводку**

```ruby
# app/services/zhk/run_summary.rb
# frozen_string_literal: true

module Zhk
  # Сводка прогона службы сбора.
  #
  # Главный тихий отказ этого класса систем — не падение парсера, а его
  # молчание: чужой сайт переверстали, разбор ничего не находит, ошибок нет.
  # Поэтому сводка сообщает не только «сколько получилось», но и «сколько
  # ожидали» — по прошлой неделе того же источника.
  module RunSummary
    SILENCE_RATIO = 0.3

    module_function

    def silent_sources(counts)
      counts.filter_map do |source, current|
        expected = previous_week_count(source)
        next if expected.zero?

        source if current.to_i < expected * SILENCE_RATIO
      end
    end

    def call(counts)
      lines = ["Обход справочника ЖК — #{Time.zone.today.strftime('%d.%m.%y')}"]
      counts.each { |source, count| lines << "#{source}: #{count}" }

      silent = silent_sources(counts)
      lines << "🚨 молчат: #{silent.join(', ')} — вероятно, сменилась вёрстка" if silent.any?
      lines.join("\n")
    end

    def previous_week_count(source)
      ZhkObservation.for_source(source)
                    .where(fetched_at: 14.days.ago..7.days.ago)
                    .count
    end
  end
end
```

Действие в контроллере (`app/controllers/webhooks/zhk_ingest_controller.rb`):

```ruby
    def summary
      counts = params.require(:counts).to_unsafe_h
      text = Zhk::RunSummary.call(counts)
      Telegram::Client.new.send_message(text, chat_id: ENV.fetch('TELEGRAM_STAFF_CHAT_ID'))
      render json: { status: 'ok' }
    end
```

Роут рядом с `post 'zhk_ingest'`:

```ruby
    post 'zhk_ingest/summary', to: 'zhk_ingest#summary', as: :zhk_ingest_summary
```

- [ ] **Step 4: Написать оркестратор**

```python
# services/zhk-registry/run.py
"""Точка входа крона: обнаружение → обогащение → отправка → сводка.

Изоляция на уровне источника: упавший адаптер не роняет прогон, остальные
доходят. Частичный результат — штатный исход, а не авария.
"""

import logging
import os

import requests
from dotenv import load_dotenv

from client import IngestClient
from sources.edinstvo import EdinstvoSource
from sources.erz import ErzSource

load_dotenv(os.path.join(os.path.dirname(__file__), ".env"))
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("zhk-registry")


def main() -> None:
    base_url = os.environ["VICTORY_BASE_URL"]
    token = os.environ["ZHK_INGEST_TOKEN"]
    contact = os.environ.get("CRAWLER_CONTACT", "info@victory62.org")

    session = requests.Session()
    sources = [ErzSource(session, contact), EdinstvoSource(session, contact)]
    client = IngestClient(base_url, token)

    counts: dict[str, int] = {}
    for source in sources:
        try:
            refs = source.discover()
            observations = []
            for ref in refs:
                try:
                    obs = source.enrich(ref)
                    if obs:
                        observations.append(obs)
                except Exception:
                    log.exception("карточка не разобралась: %s", ref.get("url"))

            client.send(observations)
            counts[source.name] = len(observations)
            log.info("%s: отправлено %d", source.name, len(observations))
        except Exception:
            log.exception("источник упал целиком: %s", source.name)
            counts[source.name] = 0

    requests.post(
        f"{base_url.rstrip('/')}/webhooks/zhk_ingest/summary",
        json={"counts": counts},
        headers={"Authorization": f"Bearer {token}"},
        timeout=30,
    )


if __name__ == "__main__":
    main()
```

```
# services/zhk-registry/crontab.example
# Обход справочника ЖК — раз в неделю, ночью с понедельника на вторник.
# Ставится в крон пользователя на хосте прода; каталог — main-чекаут.
0 3 * * 2 cd /home/q/victory/services/zhk-registry && .venv/bin/python3 run.py >> /var/log/zhk-registry.log 2>&1
```

- [ ] **Step 5: Прогнать всё**

Run: `bin/rb --db bundle exec rspec spec/services/zhk spec/requests/webhooks/zhk_ingest_controller_spec.rb && cd services/zhk-registry && python3 -m unittest discover -v`
Expected: PASS с обеих сторон

- [ ] **Step 6: Линтер и коммит**

```bash
bin/rb bundle exec rubocop app/services/zhk app/controllers/webhooks/zhk_ingest_controller.rb config/routes.rb
git add app/services/zhk/run_summary.rb app/controllers/webhooks/zhk_ingest_controller.rb config/routes.rb spec/services/zhk/run_summary_spec.rb services/zhk-registry
git commit -m "feat(zhk): оркестратор обхода, сводка прогона и детектор молчащего источника"
```

---

### Task 12: `Zhk::CatalogHints` — ЖК, названные в наших же карточках

Четвёртый источник из спеки: комплекс, упомянутый в карточке каталога, но не заведённый в справочнике. Он даёт **подсказку, а не факт** — поэтому черновиков не создаёт и в `zhk_facts` не пишет: имя из рекламного текста риэлтора это не проектная декларация. Ровно так 07.09.26 руками нашлись «Северный», «Маргелов», «Пожарский», «Лето» и «Голландия».

**Files:**
- Create: `app/services/zhk/catalog_hints.rb`
- Modify: `lib/tasks/zhk.rake` (задача `zhk:hints` рядом с `zhk:coverage` и `zhk:suggest`)
- Test: `spec/services/zhk/catalog_hints_spec.rb`

**Interfaces:**
- Consumes: `Zhk::Matcher.call`.
- Produces: `Zhk::CatalogHints.call → Array<Hash{name: String, property_ids: Array<Integer>, sample_address: String}>`.

- [ ] **Step 1: Написать падающий спек**

```ruby
# spec/services/zhk/catalog_hints_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Zhk::CatalogHints do
  it 'находит ЖК, названный в карточке, но отсутствующий в справочнике' do
    create(:property, title: 'Квартира в ЖК «Небывалый»',
                      address: 'Рязанская обл., г. Рязань, ул. Новая, д. 1')

    hint = described_class.call.first

    expect(hint[:name]).to eq('Небывалый')
    expect(hint[:sample_address]).to include('ул. Новая')
  end

  it 'молчит про ЖК, который уже заведён' do
    create(:residential_complex, name: 'Легенда', city: 'Рязань')
    create(:property, title: 'Квартира в ЖК «Легенда»',
                      address: 'Рязанская обл., г. Рязань, ул. Интернациональная, д. 20')

    expect(described_class.call).to be_empty
  end

  it 'схлопывает несколько карточек одного ЖК в одну подсказку' do
    create(:property, title: 'Однушка в ЖК «Небывалый»', address: 'Рязань, ул. Новая, д. 1')
    create(:property, title: 'Двушка в ЖК «Небывалый»', address: 'Рязань, ул. Новая, д. 3')

    expect(described_class.call.size).to eq(1)
    expect(described_class.call.first[:property_ids].size).to eq(2)
  end

  it 'не принимает за название оборот речи' do
    create(:property, title: 'Рядом с ЖК и остановкой', address: 'Рязань, ул. Новая, д. 5')

    expect(described_class.call).to be_empty
  end
end
```

- [ ] **Step 2: Убедиться, что спек падает**

Run: `bin/rb --db bundle exec rspec spec/services/zhk/catalog_hints_spec.rb`
Expected: FAIL, `uninitialized constant Zhk::CatalogHints`

- [ ] **Step 3: Реализовать**

```ruby
# app/services/zhk/catalog_hints.rb
# frozen_string_literal: true

module Zhk
  # ЖК, названные в карточках нашего каталога, но отсутствующие в
  # справочнике. Это ПОДСКАЗКА, а не факт: имя из рекламного текста риэлтора
  # не проектная декларация, поэтому ни черновик, ни запись в zhk_facts
  # отсюда не рождаются — только строка в отчёте для редактора.
  module CatalogHints
    # Имя идёт после «ЖК» и начинается с заглавной. Ограничение по длине и
    # отсечка служебных слов ниже — потому что «ЖК и репутация застройщика»
    # или «ЖК до остановки 5 минут» это оборот речи, а не название.
    MENTION_RX = /Ж[Кк]\s*[«"]?\s*([А-ЯЁ][А-Яа-яёЁ0-9\s\-.]{2,40}?)\s*[»".,;!?
]/
    STOP_WORDS = %w[и или до от рядом около близко можно уточняйте].freeze

    module_function

    def call
      hints = Hash.new { |h, k| h[k] = { property_ids: [], sample_address: nil } }

      Property.where.not(title: [nil, '']).or(Property.where.not(description: [nil, '']))
              .pluck(:id, :title, :description, :address, :city)
              .each do |id, title, description, address, city|
        names_in("#{title} #{description}").each do |name|
          next if Matcher.call(name: name, city: city.presence || 'Рязань', address: address)

          bucket = hints[name]
          bucket[:property_ids] << id
          bucket[:sample_address] ||= address
        end
      end

      hints.map { |name, data| { name: name }.merge(data) }
    end

    def names_in(text)
      text.to_s.scan(MENTION_RX).flatten.filter_map do |raw|
        name = raw.strip.squeeze(' ')
        next if name.blank?
        next if STOP_WORDS.include?(name.split.first.to_s.downcase)

        name
      end.uniq
    end
  end
end
```

Задача в `lib/tasks/zhk.rake`, рядом с существующими:

```ruby
  desc 'ЖК, названные в карточках каталога, но отсутствующие в справочнике'
  task hints: :environment do
    rows = Zhk::CatalogHints.call
    if rows.empty?
      puts '[zhk:hints] подсказок нет — каталог не называет ЖК, которых мы не знаем'
    else
      rows.each do |row|
        puts format('%-30s объектов: %-3d пример: %s',
                    row[:name], row[:property_ids].size, row[:sample_address])
      end
    end
  end
```

- [ ] **Step 4: Прогнать спек и задачу**

Run: `bin/rb --db bundle exec rspec spec/services/zhk/catalog_hints_spec.rb`
Expected: PASS, 4 examples, 0 failures

- [ ] **Step 5: Линтер и коммит**

```bash
bin/rb bundle exec rubocop app/services/zhk/catalog_hints.rb lib/tasks/zhk.rake
git add app/services/zhk/catalog_hints.rb lib/tasks/zhk.rake spec/services/zhk/catalog_hints_spec.rb
git commit -m "feat(zhk): подсказки по ЖК, названным в карточках каталога"
```

---

### Task 13: Сухой прогон на проде и документация

**Files:**
- Modify: `services/zhk-registry/README.md` (раздел «Первый запуск»), `.claude/memory/activeContext.md`

- [ ] **Step 1: Проверить вебхук вручную против локального стека**

```bash
bin/rb --web up
ZHK_INGEST_TOKEN=dev-token bin/rb --web 'bin/rails runner "puts ENV[\"ZHK_INGEST_TOKEN\"]"'
curl -s -X POST http://127.0.0.1:3001/webhooks/zhk_ingest \
  -H 'Authorization: Bearer dev-token' -H 'Content-Type: application/json' \
  -d @spec/fixtures/zhk/observation_example.json
```

Ожидаемо: JSON с `"status":"created"`. Погасить стек: `bin/rb --web down`.

- [ ] **Step 2: Прогнать службу в режиме без отправки**

В `run.py`, сразу после создания клиента:

```python
    dry_run = os.environ.get("DRY_RUN") == "1"
```

и вместо `client.send(observations)`:

```python
            if dry_run:
                for obs in observations:
                    log.info("DRY_RUN %s — %s", obs.external_id, obs.to_payload()["fields"])
            else:
                client.send(observations)
```

Отправку сводки тоже обернуть в `if not dry_run:`. Затем прогон на живых источниках — это первая проверка селекторов вне фикстур:

```bash
cd /home/q/victory-registry/services/zhk-registry && DRY_RUN=1 .venv/bin/python3 run.py
```

Ожидаемо: строки `DRY_RUN erz:… {'developer': …}` по каждой карточке. Пусто по источнику — селекторы не подошли к живой вёрстке, чинить до боевого запуска.

- [ ] **Step 3: Записать в README раздел «Первый запуск»**

Что именно: как создать venv, где взять токен, как прогнать с `DRY_RUN=1`, как поставить крон, куда смотреть логи, и главное — что делать, когда источник замолчал (обновить фикстуру, починить селектор, прогнать тесты).

- [ ] **Step 4: Обновить activeContext**

Одна секция: служба сбора появилась, что она делает, где её крон, куда смотреть при отказе.

- [ ] **Step 5: Коммит и PR**

```bash
git add services/zhk-registry/README.md .claude/memory/activeContext.md
git commit -m "docs(zhk-registry): первый запуск, крон и что делать при отказе источника"
git push -u origin claude/zhk-registry
gh pr create --title "feat(zhk): служба сбора данных о ЖК — ядро реестра и расхождения" --body "..."
```

**Обязательный этап перед мержем:** код-ревью на diff (`pr-review-toolkit:code-reviewer`) — PR не считается готовым, пока ревью не пройдено и блокеры не закрыты.

---

## Порядок и зависимости

Задачи 1→2→3→5→4→6→7 идут строго по порядку (Task 4 использует `Zhk::Discrepancies` из Task 5 — поэтому 5 выполняется раньше). Задачи 8→9→10→11 — питоновская сторона: зависят только от контракта, заведённого в Task 4, и могут идти параллельно с 5-7. Task 12 (подсказки из каталога) зависит только от Task 3 и тоже параллелится. Task 13 — последняя, ей нужно всё остальное.
