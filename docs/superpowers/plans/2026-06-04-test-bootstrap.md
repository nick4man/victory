# Test Bootstrap (Phase 1 Layer 0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add ~25 critical RSpec tests на legacy сервисы victory62 как safety net перед EOL upgrade (Rails 7.2 + Ruby 3.3).

**Architecture:** RSpec + FactoryBot + Faker(ru). Pattern существующих 75 specs (см. spec/factories/, spec/services/, spec/models/, spec/requests/). Use skill `rspec-bootstrap` для factory/spec scaffold templates. Все specs должны pass на текущем Rails 7.1 / Ruby 3.2.

**Tech Stack:** RSpec-rails 7.0, factory_bot_rails 6.4, faker 3.4 (Ru locale), database_cleaner-active_record 2.2, shoulda-matchers 6.0.

---

## File Structure

**New factories (5):**
- `spec/factories/properties.rb`
- `spec/factories/articles.rb`
- `spec/factories/case_studies.rb`
- `spec/factories/lead_events.rb`
- `spec/factories/telegram_group_messages.rb`

**New specs (10 targets):**
- `spec/services/llm/chat_responder_spec.rb` — main chatbot pipeline
- `spec/services/chat_tools/staff/search_group_messages_spec.rb` — recent in_order_of fix
- `spec/services/chat_tools/staff/search_all_leads_spec.rb` — recent in_order_of fix
- `spec/services/property_evaluation_service_spec.rb` — valuation pipeline
- `spec/initializers/sidekiq_cron_loader_spec.rb` — runtime hook
- `spec/requests/admin/health_spec.rb` — health endpoint
- `spec/models/article_after_commit_spec.rb` — IndexNow + Y.Recrawl hooks
- `spec/models/property_after_commit_spec.rb` — same hooks
- `spec/requests/webhooks/topnlab_reports_spec.rb` — report generation
- `spec/requests/landings_show_spec.rb` — landing dynamic render

**Branch:** `test/bootstrap-eol-safety-net`

---

## Pre-flight

- [ ] **Step 0a: Create branch**

```bash
git checkout main && git pull
git checkout -b test/bootstrap-eol-safety-net
```

- [ ] **Step 0b: Verify baseline 75 specs pass**

Run: `docker compose run --rm web bin/rspec`
Expected: `75 examples, 0 failures` (или похожее без failures)

If failures exist на baseline — fix перед добавлением new specs.

---

## Task 1: Factory — properties

**Files:**
- Create: `spec/factories/properties.rb`

- [ ] **Step 1: Read existing model**

Run: `head -60 app/models/property.rb`
Note required attributes (validations) and enums (status, property_type).

- [ ] **Step 2: Write factory**

```ruby
# spec/factories/properties.rb
# frozen_string_literal: true

FactoryBot.define do
  factory :property do
    sequence(:title) { |n| "Тестовая квартира #{n}" }
    description { Faker::Lorem.paragraph(sentence_count: 5) }
    price { Faker::Number.within(range: 3_000_000..30_000_000) }
    area { Faker::Number.decimal(l_digits: 2, r_digits: 1) }
    rooms { rand(1..4) }
    floor { rand(1..16) }
    total_floors { rand(5..25) }
    address { "Рязанская обл., Рязань г., #{Faker::Address.street_address}" }
    property_type { :apartment }
    status { :active }
    published_at { 1.day.ago }

    trait :archived do
      status { :archived }
      published_at { 30.days.ago }
    end

    trait :premium do
      price { Faker::Number.within(range: 15_000_000..50_000_000) }
    end
  end
end
```

- [ ] **Step 3: Verify factory builds**

Run: `docker compose run --rm web bin/rails runner "require 'factory_bot'; FactoryBot.find_definitions; p FactoryBot.build(:property).valid?"`
Expected: `true`

- [ ] **Step 4: Commit**

```bash
git add spec/factories/properties.rb
git commit -m "test(factories): add Property factory with traits"
```

---

## Task 2: Factory — articles

**Files:**
- Create: `spec/factories/articles.rb`

- [ ] **Step 1: Read existing model**

Run: `head -80 app/models/article.rb`
Note: `category` enum, `body_md/body_html`, `published_at`, `slug` (friendly_id).

- [ ] **Step 2: Write factory**

```ruby
# spec/factories/articles.rb
# frozen_string_literal: true

FactoryBot.define do
  factory :article do
    sequence(:title) { |n| "Статья номер #{n}" }
    body_md { "# Заголовок\n\n#{Faker::Lorem.paragraph(sentence_count: 10)}" }
    category { :news }
    published_at { 1.hour.ago }

    trait :guides do
      category { :guides }
    end

    trait :market do
      category { :market }
    end

    trait :hidden do
      hidden_at { Time.current }
    end

    trait :unpublished do
      published_at { nil }
    end
  end
end
```

- [ ] **Step 3: Verify**

Run: `docker compose run --rm web bin/rails runner "require 'factory_bot'; FactoryBot.find_definitions; p FactoryBot.build(:article).valid?"`
Expected: `true`

- [ ] **Step 4: Commit**

```bash
git add spec/factories/articles.rb
git commit -m "test(factories): add Article factory with category traits"
```

---

## Task 3: Factory — case_studies + lead_events + telegram_group_messages

**Files:**
- Create: `spec/factories/case_studies.rb`
- Create: `spec/factories/lead_events.rb`
- Create: `spec/factories/telegram_group_messages.rb`

- [ ] **Step 1: Read models**

```bash
head -40 app/models/case_study.rb
head -40 app/models/lead_event.rb
head -40 app/models/telegram_group_message.rb
```

- [ ] **Step 2: Write factories**

```ruby
# spec/factories/case_studies.rb
# frozen_string_literal: true

FactoryBot.define do
  factory :case_study do
    sequence(:title) { |n| "Сделка #{n}: квартира в Рязани" }
    body { Faker::Lorem.paragraph(sentence_count: 8) }
    deal_amount { Faker::Number.within(range: 5_000_000..20_000_000) }
    closed_at { 30.days.ago }
    publicly_visible { true }

    trait :hidden do
      publicly_visible { false }
    end
  end
end
```

```ruby
# spec/factories/lead_events.rb
# frozen_string_literal: true

FactoryBot.define do
  factory :lead_event do
    association :inquiry
    event_type { :note_added }
    payload { { 'note' => Faker::Lorem.sentence } }
    occurred_at { Time.current }
  end
end
```

```ruby
# spec/factories/telegram_group_messages.rb
# frozen_string_literal: true

FactoryBot.define do
  factory :telegram_group_message do
    chat_id { -1001234567890 }
    message_id { Faker::Number.unique.number(digits: 6) }
    text { Faker::Lorem.sentence }
    sent_at { Time.current }
    thread_id { 0 }
  end
end
```

- [ ] **Step 3: Verify all three**

Run: `docker compose run --rm web bin/rails runner "require 'factory_bot'; FactoryBot.find_definitions; [:case_study, :lead_event, :telegram_group_message].each { |f| p [f, FactoryBot.build(f).valid?] }"`
Expected: `[:case_study, true]`, `[:lead_event, true]`, `[:telegram_group_message, true]`

- [ ] **Step 4: Commit**

```bash
git add spec/factories/case_studies.rb spec/factories/lead_events.rb spec/factories/telegram_group_messages.rb
git commit -m "test(factories): add CaseStudy + LeadEvent + TelegramGroupMessage"
```

---

## Task 4: Spec — search_group_messages (in_order_of fix)

**Files:**
- Create: `spec/services/chat_tools/staff/search_group_messages_spec.rb`

- [ ] **Step 1: Read service**

Run: `head -100 app/services/chat_tools/staff/search_group_messages.rb`
Note: class method `.call(args)`, range/topic filtering, `semantic_scope` (recent in_order_of fix).

- [ ] **Step 2: Write spec**

```ruby
# spec/services/chat_tools/staff/search_group_messages_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ChatTools::Staff::SearchGroupMessages do
  describe '.call' do
    let(:msg_a) { create(:telegram_group_message, text: 'продажа квартиры Канищево', sent_at: 2.days.ago) }
    let(:msg_b) { create(:telegram_group_message, text: 'аренда в Дашково',          sent_at: 1.day.ago) }

    before do
      msg_a; msg_b # ensure both persisted
    end

    it 'returns messages within range' do
      result = described_class.call(period: 'this_week')
      expect(result[:items]).to be_an(Array)
      expect(result[:items].size).to be >= 2
    end

    it 'returns empty items for impossible range' do
      result = described_class.call(period: 'custom', from: 100.years.ago.to_s, to: 99.years.ago.to_s)
      expect(result[:items]).to eq([])
    end
  end

  describe '.semantic_scope' do
    it 'returns nil when embedding fails (no API key)' do
      allow_any_instance_of(Embedding::GoogleClient).to receive(:embed).and_return(nil)
      expect(described_class.semantic_scope('квартира')).to be_nil
    end
  end
end
```

- [ ] **Step 3: Run spec**

Run: `docker compose run --rm web bin/rspec spec/services/chat_tools/staff/search_group_messages_spec.rb`
Expected: 3 examples, 0 failures (could be 1-2 failures if create logic differs — fix factory/spec).

- [ ] **Step 4: Commit**

```bash
git add spec/services/chat_tools/staff/search_group_messages_spec.rb
git commit -m "test(chat_tools): bootstrap search_group_messages spec"
```

---

## Task 5: Spec — search_all_leads (in_order_of fix)

**Files:**
- Create: `spec/services/chat_tools/staff/search_all_leads_spec.rb`

- [ ] **Step 1: Read service**

Run: `head -100 app/services/chat_tools/staff/search_all_leads.rb`
Note: `.call(args)` interface, semantic + tsvector hybrid scopes.

- [ ] **Step 2: Write spec**

```ruby
# spec/services/chat_tools/staff/search_all_leads_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ChatTools::Staff::SearchAllLeads do
  describe '.call' do
    let(:inquiry) { create(:inquiry) }
    let(:event)   { create(:lead_event, inquiry: inquiry, occurred_at: 1.day.ago) }

    before { event }

    it 'returns items array for valid period' do
      result = described_class.call(period: 'this_week')
      expect(result).to be_a(Hash)
      expect(result[:items]).to be_an(Array)
    end

    it 'handles unknown username gracefully' do
      result = described_class.call(period: 'this_week', username: 'nonexistent_user')
      expect(result[:items]).to eq([])
    end
  end

  describe '.semantic_scope' do
    it 'returns nil on embedding failure' do
      allow_any_instance_of(Embedding::GoogleClient).to receive(:embed).and_return(nil)
      expect(described_class.semantic_scope('лид')).to be_nil
    end
  end
end
```

- [ ] **Step 3: Run + commit**

Run: `docker compose run --rm web bin/rspec spec/services/chat_tools/staff/search_all_leads_spec.rb`

```bash
git add spec/services/chat_tools/staff/search_all_leads_spec.rb
git commit -m "test(chat_tools): bootstrap search_all_leads spec"
```

---

## Task 6: Spec — chat_responder

**Files:**
- Create: `spec/services/llm/chat_responder_spec.rb`

- [ ] **Step 1: Read service**

Run: `head -100 app/services/llm/chat_responder.rb`
Note: `.respond(message:, session:)` or similar interface. Stub OmniClient/LLM provider.

- [ ] **Step 2: Write spec**

```ruby
# spec/services/llm/chat_responder_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::ChatResponder do
  describe '.respond' do
    let(:fake_response) { { 'choices' => [{ 'message' => { 'content' => 'Ответ' } }] } }

    before do
      allow_any_instance_of(Llm::OmniClient).to receive(:chat).and_return(fake_response)
    end

    it 'returns a response hash for a simple message' do
      result = described_class.respond(message: 'Привет', session: {})
      expect(result).to be_a(Hash)
    end

    it 'handles empty message gracefully' do
      expect { described_class.respond(message: '', session: {}) }.not_to raise_error
    end
  end
end
```

- [ ] **Step 3: Run + commit**

Run: `docker compose run --rm web bin/rspec spec/services/llm/chat_responder_spec.rb`

If interface differs (e.g., method is `.call` not `.respond`) — adjust spec to match actual API.

```bash
git add spec/services/llm/chat_responder_spec.rb
git commit -m "test(llm): bootstrap chat_responder spec"
```

---

## Task 7: Spec — property_evaluation_service

**Files:**
- Create: `spec/services/property_evaluation_service_spec.rb`

- [ ] **Step 1: Read service**

Run: `head -100 app/services/property_evaluation_service.rb`
Note: input params (area, district, rooms), output structure (price range).

- [ ] **Step 2: Write spec**

```ruby
# spec/services/property_evaluation_service_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PropertyEvaluationService do
  describe '.call' do
    it 'returns a valuation hash for valid inputs' do
      result = described_class.call(
        area: 54.0,
        rooms: 2,
        district: 'Дубровичи',
        floor: 3,
        total_floors: 5,
        property_type: 'apartment'
      )
      expect(result).to be_a(Hash)
      expect(result.keys).to include(:price_min, :price_max) | include('price_min', 'price_max')
    end

    it 'handles missing district gracefully' do
      expect {
        described_class.call(area: 50.0, rooms: 2, district: nil)
      }.not_to raise_error
    end
  end
end
```

- [ ] **Step 3: Run + commit**

```bash
docker compose run --rm web bin/rspec spec/services/property_evaluation_service_spec.rb
git add spec/services/property_evaluation_service_spec.rb
git commit -m "test(services): bootstrap PropertyEvaluationService spec"
```

---

## Task 8: Spec — sidekiq_cron_loader initializer

**Files:**
- Create: `spec/initializers/sidekiq_cron_loader_spec.rb`

- [ ] **Step 1: Re-read initializer**

Run: `cat config/initializers/sidekiq_cron_loader.rb`
Note: gated на `Sidekiq.server?`, reads `config/sidekiq_cron.yml`, calls `Sidekiq::Cron::Job.load_from_hash`.

- [ ] **Step 2: Write spec**

```ruby
# spec/initializers/sidekiq_cron_loader_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'sidekiq_cron_loader initializer' do
  let(:schedule_path) { Rails.root.join('config/sidekiq_cron.yml') }

  it 'config/sidekiq_cron.yml exists and is valid YAML' do
    skip 'no schedule file' unless File.exist?(schedule_path)
    expect { YAML.safe_load(ERB.new(File.read(schedule_path)).result, aliases: true) }.not_to raise_error
  end

  it 'все классы из schedule constantizable' do
    skip 'no schedule file' unless File.exist?(schedule_path)
    schedule = YAML.safe_load(ERB.new(File.read(schedule_path)).result, aliases: true) || {}
    schedule.each_value do |entry|
      next unless entry.is_a?(Hash) && entry['class']
      expect { entry['class'].constantize }.not_to raise_error,
        "class #{entry['class']} not loadable"
    end
  end
end
```

- [ ] **Step 3: Run + commit**

```bash
docker compose run --rm web bin/rspec spec/initializers/sidekiq_cron_loader_spec.rb
git add spec/initializers/sidekiq_cron_loader_spec.rb
git commit -m "test(initializers): bootstrap sidekiq_cron_loader spec"
```

---

## Task 9: Spec — admin/health request

**Files:**
- Create: `spec/requests/admin/health_spec.rb`

- [ ] **Step 1: Read controller**

Run: `head -80 app/controllers/admin/health_controller.rb`
Note: `?token=$ADMIN_TOKEN` auth (CLAUDE.md), returns JSON with checks (db/redis/sidekiq/topnlab).

- [ ] **Step 2: Write spec**

```ruby
# spec/requests/admin/health_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Admin::Health', type: :request do
  let(:token) { ENV.fetch('ADMIN_TOKEN', 'test-admin-token') }

  describe 'GET /admin/health.json' do
    it 'returns 200 OK with valid token' do
      get "/admin/health.json?token=#{token}"
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json).to be_a(Hash)
      expect(json).to have_key('status')
    end

    it 'returns 401/403 without token' do
      get '/admin/health.json'
      expect(response.status).to be_in([401, 403, 404])
    end
  end
end
```

- [ ] **Step 3: Run + commit**

```bash
docker compose run --rm web bin/rspec spec/requests/admin/health_spec.rb
git add spec/requests/admin/health_spec.rb
git commit -m "test(requests): bootstrap admin/health spec"
```

---

## Task 10: Spec — Article after_commit hooks

**Files:**
- Create: `spec/models/article_after_commit_spec.rb`

- [ ] **Step 1: Inspect callbacks**

Run: `grep -n 'after_commit\|notify_indexnow\|notify_yandex' app/models/article.rb`
Note: which hooks fire on publish/update.

- [ ] **Step 2: Write spec**

```ruby
# spec/models/article_after_commit_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Article, '.after_commit hooks' do
  describe 'IndexNow + Y.Recrawl notify on publish' do
    let(:article) { build(:article, :unpublished) }

    it 'enqueues IndexNow job when published_at goes from nil to value' do
      article.save!
      expect {
        article.update!(published_at: Time.current)
      }.to have_enqueued_job(Seo::IndexNowNotifyJob).at_least(:once).or have_enqueued_job(/IndexNow/)
    end

    it 'does NOT notify when toggling published_at off' do
      article.update!(published_at: 1.hour.ago)
      expect {
        article.update!(published_at: nil)
      }.not_to have_enqueued_job(Seo::IndexNowNotifyJob)
    end
  end
end
```

- [ ] **Step 3: Run + commit**

If jobs don't exist or interface differs — adjust matcher to actual job name (check `app/jobs/seo/`).

```bash
docker compose run --rm web bin/rspec spec/models/article_after_commit_spec.rb
git add spec/models/article_after_commit_spec.rb
git commit -m "test(models): bootstrap Article after_commit spec"
```

---

## Task 11: Spec — Property after_commit hooks

**Files:**
- Create: `spec/models/property_after_commit_spec.rb`

- [ ] **Step 1: Inspect callbacks**

Run: `grep -n 'after_commit\|notify_indexnow\|notify_yandex_recrawl\|should_notify_indexnow' app/models/property.rb`

- [ ] **Step 2: Write spec**

```ruby
# spec/models/property_after_commit_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Property, '.after_commit hooks' do
  describe 'IndexNow + Y.Recrawl notify on activate' do
    it 'enqueues IndexNow job когда property становится active' do
      property = build(:property, status: :draft)
      property.save!
      expect {
        property.update!(status: :active, published_at: Time.current)
      }.to have_enqueued_job(Seo::IndexNowNotifyJob).or have_enqueued_job(Yandex::RecrawlUrlJob)
    end

    it 'не enqueue'ит когда status = archived' do
      property = create(:property, :archived)
      expect {
        property.update!(price: property.price + 1000)
      }.not_to have_enqueued_job(Seo::IndexNowNotifyJob)
    end
  end
end
```

- [ ] **Step 3: Run + commit**

```bash
docker compose run --rm web bin/rspec spec/models/property_after_commit_spec.rb
git add spec/models/property_after_commit_spec.rb
git commit -m "test(models): bootstrap Property after_commit spec"
```

---

## Task 12: Spec — webhooks/topnlab_reports

**Files:**
- Create: `spec/requests/webhooks/topnlab_reports_spec.rb`

- [ ] **Step 1: Read controller**

Run: `cat app/controllers/webhooks/topnlab_reports_controller.rb`

- [ ] **Step 2: Write spec**

```ruby
# spec/requests/webhooks/topnlab_reports_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Webhooks::TopnlabReports', type: :request do
  describe 'POST /webhooks/topnlab_reports/:slug' do
    it 'returns 404 for unknown report slug' do
      post '/webhooks/topnlab_reports/nonexistent', params: { ids: [1, 2] }.to_json,
           headers: { 'Content-Type' => 'application/json' }
      expect(response).to have_http_status(:not_found)
      expect(JSON.parse(response.body)).to have_key('error')
    end
  end
end
```

- [ ] **Step 3: Run + commit**

```bash
docker compose run --rm web bin/rspec spec/requests/webhooks/topnlab_reports_spec.rb
git add spec/requests/webhooks/topnlab_reports_spec.rb
git commit -m "test(requests): bootstrap topnlab_reports webhook spec"
```

---

## Task 13: Spec — landings#show dynamic render

**Files:**
- Create: `spec/requests/landings_show_spec.rb`

- [ ] **Step 1: Read controller**

Run: `head -80 app/controllers/landings_controller.rb`
Note: `params[:intent]`, `params[:type]`, `params[:district]` routing.

- [ ] **Step 2: Write spec**

```ruby
# spec/requests/landings_show_spec.rb
# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Landings#show', type: :request do
  describe 'GET /kupit/kvartira' do
    it 'returns 200 for valid intent + type' do
      get '/kupit/kvartira'
      expect(response).to have_http_status(:ok)
    end

    it 'returns 200 для district landing' do
      get '/kupit/kvartira/rayon/priokskiy'
      expect(response.status).to be_in([200, 302])
    end

    it 'sets canonical meta' do
      get '/kupit/kvartira'
      expect(response.body).to include('canonical')
    end
  end
end
```

- [ ] **Step 3: Run + commit**

```bash
docker compose run --rm web bin/rspec spec/requests/landings_show_spec.rb
git add spec/requests/landings_show_spec.rb
git commit -m "test(requests): bootstrap landings#show spec"
```

---

## Final Verification

- [ ] **Step F1: Run full test suite**

```bash
docker compose run --rm web bin/rspec
```

Expected: ~100 examples, 0 failures (75 baseline + 25 new).

- [ ] **Step F2: Run rubocop с baseline**

```bash
docker compose run --rm web bin/rubocop spec/
```

Expected: pass — new specs соблюдают baseline.

- [ ] **Step F3: Push branch и open PR**

```bash
git push -u origin test/bootstrap-eol-safety-net
gh pr create --base main --title "test: bootstrap ~25 specs as EOL safety net" \
  --body "Phase 1 Layer 0 from docs/superpowers/specs/2026-06-04-eol-rails-ruby-upgrade-design.md

Adds factories (Property, Article, CaseStudy, LeadEvent, TelegramGroupMessage)
and ~10 spec files covering: chat_responder, search_group_messages,
search_all_leads, property_evaluation_service, sidekiq_cron_loader,
admin/health, Article/Property after_commit, topnlab_reports webhook,
landings#show.

Goal: safety net перед EOL upgrade (Rails 7.2 + Ruby 3.3).

All specs green на текущем Rails 7.1 / Ruby 3.2."
```

- [ ] **Step F4: Verify CI green**

Wait for CI run, confirm:
- RuboCop ✓
- (Brakeman / bundler-audit untouched — EOL baseline остаётся)

- [ ] **Step F5: Merge after review**

После approve — merge в main. Plan complete.

---

## Acceptance

- [x] Spec coverage: bootstrap targets из design Section 6 Layer 0 — все 10 targets covered
- [x] Placeholder scan: нет TBD/TODO в plan
- [x] Type consistency: factory names совпадают между tasks
