---
name: rspec-bootstrap
description: Use when bootstrapping RSpec tests for legacy code in victory62 — generating factories, model specs, service specs, request specs. Critical because the project has only 5 spec files for 328 modules. Captures the project's RSpec patterns (FactoryBot, Faker:ru, DatabaseCleaner, request specs over controller specs, admin-token auth setup). RELATED (.claude/docs/delegation-map.md) — for ACTUAL execution of a bootstrap (write factory + spec + verify) use agent `test-bootstrapper`; pair with agent `rails-architect` when tests are added as a safety net BEFORE a planned refactor.
---

# RSpec Bootstrap — victory62

## When to use

- Bootstrapping тестов для существующего untested сервиса/контроллера/модели
- Создание factory для модели у которой её нет
- Перед refactoring — minimal coverage как safety net

## Project setup (что уже работает)

- **RSpec**, `spec/rails_helper.rb`, `spec/spec_helper.rb`
- **FactoryBot** included globally (`FactoryBot::Syntax::Methods`)
- **Faker** locale `:ru` (русские имена, адреса, телефоны)
- **DatabaseCleaner** — transaction strategy (truncation для JS specs)
- **Shoulda Matchers** для validations/associations
- **Capybara** + `selenium_chrome_headless` для JS specs
- **request specs** preferred over controller specs (Rails 5+ pattern)

## Standard templates

### Factory

```ruby
# spec/factories/properties.rb
FactoryBot.define do
  factory :property do
    user
    title { "#{Faker::Lorem.word.capitalize} #{Faker::Address.street_name}" }
    description { Faker::Lorem.paragraph }
    price { Faker::Number.between(from: 3_000_000, to: 15_000_000) }
    area { Faker::Number.between(from: 30, to: 120) }
    rooms { rand(1..4) }
    deal_type { :sale }
    status { :draft }
    address { Faker::Address.full_address }
    district { %w[Дубровичи Канищево Солотча Дашково-Песочня].sample }

    trait :active do
      status { :active }
      published_at { Time.current }
    end

    trait :sold { status { :sold } }
    trait :with_images do
      after(:create) do |property|
        # attach blob if Active Storage
      end
    end
  end
end
```

### Model spec — golden path

```ruby
# spec/models/property_spec.rb
require 'rails_helper'

RSpec.describe Property, type: :model do
  describe 'associations' do
    it { is_expected.to belong_to(:user).optional }
    it { is_expected.to have_many(:favorites).dependent(:destroy) }
    it { is_expected.to have_many(:inquiries) }
  end

  describe 'validations' do
    it { is_expected.to validate_presence_of(:title) }
    it { is_expected.to validate_numericality_of(:price).is_greater_than(0) }
  end

  describe 'enums' do
    it 'defines deal_type with _prefix' do
      expect(Property.deal_types.keys).to contain_exactly('sale', 'rent', 'daily')
    end

    it 'has _prefix? methods' do
      expect(build(:property, deal_type: :sale)).to be_deal_type_sale
    end
  end

  describe 'soft delete' do
    let!(:property) { create(:property) }

    it 'sets deleted_at on soft_delete!' do
      expect { property.soft_delete! }
        .to change { property.reload.deleted_at }.from(nil)
    end

    it 'is excluded from default scope after soft_delete!' do
      property.soft_delete!
      expect(Property.where(id: property.id)).to be_empty
      expect(Property.unscoped.where(id: property.id)).to exist
    end
  end

  describe '#publish!' do
    let(:property) { create(:property, status: :draft) }

    it 'transitions to active' do
      property.publish!
      expect(property.reload).to be_status_active
    end

    it 'sets published_at' do
      property.publish!
      expect(property.reload.published_at).to be_within(1.second).of(Time.current)
    end
  end
end
```

### Service spec — Result-hash

```ruby
# spec/services/property_evaluation_service_spec.rb
require 'rails_helper'

RSpec.describe PropertyEvaluationService do
  subject(:result) { described_class.new(params).call }

  context 'with valid 2-room apartment' do
    let(:params) do
      {
        rooms: 2, area: 54, district: 'Дубровичи',
        condition: :normal, floor: 3, total_floors: 5
      }
    end

    it { expect(result[:ok]).to be true }

    it 'returns positive estimate' do
      expect(result[:value][:price]).to be_positive
    end

    it 'returns CI within reasonable range' do
      v = result[:value]
      expect(v[:ci_high] - v[:ci_low]).to be < (v[:price] * 0.6)
    end
  end

  context 'with missing area' do
    let(:params) { { rooms: 2, district: 'Дубровичи' } }

    it 'returns error result' do
      expect(result[:ok]).to be false
      expect(result[:error]).to include(:area)
    end
  end
end
```

### Request spec — admin token auth

```ruby
# spec/requests/admin/reviews_spec.rb
require 'rails_helper'

RSpec.describe 'Admin::Reviews', type: :request do
  let(:admin_token) { 'test-admin-token' }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('ADMIN_TOKEN').and_return(admin_token)
  end

  describe 'GET /admin/reviews' do
    let!(:review) { create(:review) }

    context 'without token' do
      it 'returns 403' do
        get admin_reviews_path
        expect(response).to have_http_status(:forbidden)
      end
    end

    context 'with valid token' do
      it 'returns 200 and lists reviews' do
        get admin_reviews_path, params: { token: admin_token }
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(review.author_name)
      end
    end
  end
end
```

### Job spec

```ruby
# spec/jobs/topnlab_property_import_job_spec.rb
require 'rails_helper'

RSpec.describe TopnlabPropertyImportJob, type: :job do
  describe '#perform' do
    let(:sync_run) { create(:topnlab_sync_run) }
    let(:fake_listing) { { 'id' => 'tn-123', 'title' => 'Test', 'price' => 5_000_000 } }

    before do
      allow_any_instance_of(MlsSync::TopnlabSyncService)
        .to receive(:fetch_listings).and_return([fake_listing])
    end

    it 'creates Property' do
      expect { described_class.new.perform(sync_run.id) }
        .to change(Property, :count).by(1)
    end

    it 'updates sync_run stats' do
      described_class.new.perform(sync_run.id)
      expect(sync_run.reload.imported_count).to eq(1)
    end
  end
end
```

## Run commands

```bash
# Все specs
bundle exec rspec

# Конкретный файл
bundle exec rspec spec/models/property_spec.rb

# Конкретный example
bundle exec rspec spec/models/property_spec.rb:42

# С документацией
bundle exec rspec --format documentation

# Только failing
bundle exec rspec --only-failures
```

## Anti-patterns (НЕ делай)

- ❌ Мокать БД в integration specs — у нас auto-memory `feedback` запрещает. Используй FactoryBot + DatabaseCleaner.
- ❌ Писать 50 тестов на один method — start with 4: golden + 2 edges + 1 failure
- ❌ `before(:all) { create(:foo) }` — конфликт с DatabaseCleaner transaction strategy
- ❌ Дублировать `subject` и `let(:result)` — выбери один
- ❌ Тестировать private методы напрямую через `.send(:private_method)` — тестируй через public interface
- ❌ Использовать `controller specs` (`type: :controller`) — preferred `request specs` (`type: :request`)

## Что делать когда метод не покрыть тестом

Иногда (рандом, LLM, внешний API) hard-to-test. Опции:

1. **Inject dependency**: вместо `OmniClient.new.call` — `@llm.call`, где `@llm = OmniClient.new`. В spec можно подменить.
2. **WebMock / VCR** для HTTP. Cassettes в `spec/cassettes/`.
3. **Stub time** (`Timecop.freeze` или Rails `travel_to`)
4. **Random**: `srand(42)` для воспроизводимости

## Session-split note

`bundle exec rspec` — **только в victory-сессии** (Ruby 3.2.2 + bundle).
В chat-сессии можно только design spec без run.

## When to call this skill

- При создании любого нового сервиса/контроллера/модели
- Перед рефакторингом legacy кода
- При получении user request «нужны тесты на X»
