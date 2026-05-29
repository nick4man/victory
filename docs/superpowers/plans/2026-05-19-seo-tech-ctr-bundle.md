# SEO Tech/CTR Bundle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement 4 sub-systems (CWV audit+fixes, Article enrichment, HowTo Schema for guides, /blog/category hub-pages) to boost CTR and ranking signals based on Y.Webmaster data (SQI=10, 0 clicks across 12 indexed queries).

**Architecture:** Sequential build — CWV audit first (data informs other decisions), then Schema additions (Article enrichment foundation → HowTo dependent on it), then topology (hub pages depend on Article scoping). All additions backward-compatible; existing pages continue working.

**Tech Stack:** Rails 7.1 / Ruby 3.2.2 / PostgreSQL 15+ + RSpec + Nokogiri (already in Gemfile for HowTo parser) + Chrome DevTools MCP (for Lighthouse). Schema.org JSON-LD via existing partials. Faraday for Y.Webmaster recrawl (existing service).

**Spec:** [`docs/superpowers/specs/2026-05-19-seo-tech-ctr-bundle-design.md`](../specs/2026-05-19-seo-tech-ctr-bundle-design.md)

---

## Task 0: Pre-flight baseline

**Files:**
- Read: `docs/superpowers/specs/2026-05-19-seo-tech-ctr-bundle-design.md`

- [ ] **Step 1: Verify dev server up**

Run: `curl -sI http://localhost:3000/ | head -1`
Expected: `HTTP/1.1 200 OK`

- [ ] **Step 2: Smoke 10 baseline URLs**

```bash
cd /home/q/victory
for url in / /properties /about /reviews /blog /cases /valuations/new /kupit/kvartira /kupit/kvartira/rayon/centr /sitemap-news.xml; do
  code=$(curl -sI -o /dev/null -w "%{http_code}" "http://localhost:3000$url")
  printf '  %-40s %s\n' "$url" "$code"
done
```

Expected: все 200/302. Если что-то 500 — fix first, не двигаться.

- [ ] **Step 3: Confirm Article fixture exists for guides category**

Run: `docker compose exec -T web bin/rails runner 'puts Article.where(category: "guides").pluck(:id, :slug).inspect'`
Expected: at least `[[2, "kak-proverit-..."]]` (или similar)

- [ ] **Step 4: Confirm RSpec baseline**

Run: `docker compose exec -T web bundle exec rspec --no-color 2>&1 | tail -10`
Expected: existing specs pass или document fail (baseline note — не блокирует, мы дополняем).

- [ ] **Step 5: Verify Chrome DevTools MCP available**

Check `mcp__plugin_chrome-devtools-mcp_chrome-devtools__lighthouse_audit` schema via ToolSearch.
Expected: tool schema loads.

---

## Task 1: CWV Audit — measure 10 URLs via Lighthouse

**Files:**
- Create: `.claude/docs/seo/cwv-audit-2026-05-19.md`

- [ ] **Step 1: Run Lighthouse on homepage**

Use tool: `mcp__plugin_chrome-devtools-mcp_chrome-devtools__lighthouse_audit` with `url: 'https://victory62.org/'`, `categories: ['performance']`.
Capture LCP/CLS/INP/TTI/Speed Index from response.

- [ ] **Step 2: Run Lighthouse on остальные 9 URLs**

URLs:
```
https://victory62.org/properties
https://victory62.org/properties/<grab-first-active-slug>
https://victory62.org/about
https://victory62.org/reviews
https://victory62.org/blog
https://victory62.org/blog/<grab-first-recent-slug>
https://victory62.org/kupit/kvartira
https://victory62.org/kupit/kvartira/rayon/centr
https://victory62.org/valuations/new
```

Capture metrics для each.

- [ ] **Step 3: Create audit doc**

```bash
mkdir -p /home/q/victory/.claude/docs/seo
```

Write to `.claude/docs/seo/cwv-audit-2026-05-19.md` со следующей структурой:

```markdown
# CWV Audit — 2026-05-19

Measured via Lighthouse 11 (Chrome DevTools MCP). Thresholds:
- LCP good <2.5s | needs work 2.5-4s | poor >4s
- CLS good <0.1 | needs work 0.1-0.25 | poor >0.25
- INP good <200ms | needs work 200-500ms | poor >500ms

## Results

| URL | LCP | CLS | INP | TTI | SI | Verdict |
|---|---:|---:|---:|---:|---:|---|
| / | X.Xs | 0.XX | XXms | X.Xs | X.Xs | <good/needs/poor> |
| ... (10 rows total)

## Top-3 fix candidates (ranked by impact)

1. **<page>** — **<metric>** = <value> (vs target <target>). Root cause: <observation>. Fix: <concrete change>.
2. ...
3. ...

## Deferred (out of this sprint's budget)

- <issue> — reason: <too-large/needs-redesign/etc>
```

- [ ] **Step 4: Commit audit doc**

```bash
cd /home/q/victory
git add .claude/docs/seo/cwv-audit-2026-05-19.md
GIT_AUTHOR_NAME="Claude Code" GIT_AUTHOR_EMAIL="noreply@anthropic.com" \
  git commit -m "docs(seo): CWV audit 2026-05-19 — Lighthouse baseline + ranked fixes"
```

Expected: 1 file changed, commit created.

---

## Task 2: CWV fix #1 — apply top-ranked issue from audit

**Files:**
- Modify: TBD by audit (predicted: `app/views/shared/_photo_slider.html.erb` OR `_yandex_reviews_widget.html.erb` OR `app/helpers/property_image_helper.rb`)

- [ ] **Step 1: Read top-ranked issue from audit doc**

Open `.claude/docs/seo/cwv-audit-2026-05-19.md`, identify Top-1 fix candidate (page + metric + root cause + fix).

- [ ] **Step 2: Apply minimal fix**

If photo-slider eager-loading issue:
- Open `app/views/shared/_photo_slider.html.erb`
- Verify `loading="<%= i.zero? ? 'eager' : 'lazy' %>"` уже на месте — если нет, добавить
- Verify только slide i=0 имеет `fetchpriority="high"`

If Yandex iframe blocking:
- Open `app/views/shared/_yandex_reviews_widget.html.erb`
- Wrap iframe loading через IntersectionObserver (lazy until viewport)

If responsive images missing:
- Open `app/helpers/property_image_helper.rb`
- Add `srcset` + `sizes` attributes to thumbnail helpers

Concrete code зависит от audit findings — engineer applies based on doc.

- [ ] **Step 3: Re-run Lighthouse on фикс'еной page**

Use same Chrome DevTools MCP tool. Compare new metric to baseline.

- [ ] **Step 4: Verify improvement**

If LCP/CLS/INP improved by ≥10% — proceed.
If got worse OR no change — revert, document in audit doc as "fix attempted, no improvement", skip remaining steps.

- [ ] **Step 5: Commit fix**

```bash
cd /home/q/victory
git add <modified-file>
GIT_AUTHOR_NAME="Claude Code" GIT_AUTHOR_EMAIL="noreply@anthropic.com" \
  git commit -m "perf(seo): CWV fix #1 — <metric> on <page> from <before> to <after>"
```

---

## Task 3: CWV fix #2 — apply second-ranked issue

Same pattern as Task 2 для top-2 issue.

- [ ] **Step 1: Read Top-2 fix candidate from audit doc**
- [ ] **Step 2: Apply fix**
- [ ] **Step 3: Re-run Lighthouse**
- [ ] **Step 4: Verify improvement**
- [ ] **Step 5: Commit**

---

## Task 4: CWV fix #3 — apply third-ranked issue

Same pattern as Task 2 для top-3 issue.

- [ ] **Step 1: Read Top-3 fix candidate from audit doc**
- [ ] **Step 2: Apply fix**
- [ ] **Step 3: Re-run Lighthouse**
- [ ] **Step 4: Verify improvement**
- [ ] **Step 5: Commit**

---

## Task 5: Article#word_count + reading_time_minutes + iso_duration

**Files:**
- Modify: `app/models/article.rb`
- Test: `spec/models/article_spec.rb`

- [ ] **Step 1: Write failing test**

Open `spec/models/article_spec.rb` (or create if missing). Add:

```ruby
require 'rails_helper'

RSpec.describe Article, type: :model do
  describe '#word_count' do
    it 'counts words в plain text after stripping HTML' do
      article = Article.new(body_html: '<p>Word one</p><p>Word two three.</p>')
      expect(article.word_count).to eq(5)
    end

    it 'returns 0 для empty body_html' do
      article = Article.new(body_html: '')
      expect(article.word_count).to eq(0)
    end
  end

  describe '#reading_time_minutes' do
    it 'returns 1 для articles with 0 words (defensive)' do
      article = Article.new(body_html: '')
      expect(article.reading_time_minutes).to eq(1)
    end

    it 'computes 200 wpm rounded up' do
      article = Article.new(body_html: '<p>' + ('word ' * 199) + '</p>')
      expect(article.reading_time_minutes).to eq(1)
    end

    it 'rounds up 201 words to 2 minutes' do
      article = Article.new(body_html: '<p>' + ('word ' * 201) + '</p>')
      expect(article.reading_time_minutes).to eq(2)
    end
  end

  describe '#iso_duration' do
    it 'formats reading time as ISO 8601 PTxM' do
      article = Article.new(body_html: '<p>' + ('word ' * 400) + '</p>')
      expect(article.iso_duration).to eq('PT2M')
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose exec -T web bundle exec rspec spec/models/article_spec.rb --no-color 2>&1 | tail -20`
Expected: FAIL with `NoMethodError: undefined method 'word_count'` или similar.

- [ ] **Step 3: Implement methods in Article model**

Open `app/models/article.rb`. Add (anywhere в model body):

```ruby
def word_count
  ActionView::Base.full_sanitizer.sanitize(body_html.to_s).split.size
end

def reading_time_minutes
  return 1 if word_count.zero?

  (word_count / 200.0).ceil
end

def iso_duration
  "PT#{reading_time_minutes}M"
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker compose exec -T web bundle exec rspec spec/models/article_spec.rb --no-color 2>&1 | tail -10`
Expected: All examples pass, 0 failures.

- [ ] **Step 5: Commit**

```bash
cd /home/q/victory
git add spec/models/article_spec.rb app/models/article.rb
GIT_AUTHOR_NAME="Claude Code" GIT_AUTHOR_EMAIL="noreply@anthropic.com" \
  git commit -m "feat(article): word_count + reading_time_minutes + iso_duration helpers"
```

---

## Task 6: Article#keywords_for_seo

**Files:**
- Modify: `app/models/article.rb`
- Test: `spec/models/article_spec.rb` (append)

- [ ] **Step 1: Write failing test (append to existing spec)**

Add to `spec/models/article_spec.rb`:

```ruby
  describe '#keywords_for_seo' do
    it 'returns hashtags from metadata stripped of # prefix' do
      article = Article.new(metadata: { 'hashtags' => ['#ипотека', '#ставкаЦБ', 'инфляция'] })
      expect(article.keywords_for_seo).to eq(['ипотека', 'ставкаЦБ', 'инфляция'])
    end

    it 'falls back to [category] when no hashtags' do
      article = Article.new(category: 'guides', metadata: {})
      expect(article.keywords_for_seo).to eq(['guides'])
    end

    it 'falls back to [category] when metadata is nil' do
      article = Article.new(category: 'news')
      expect(article.keywords_for_seo).to eq(['news'])
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose exec -T web bundle exec rspec spec/models/article_spec.rb -e 'keywords_for_seo' --no-color 2>&1 | tail -10`
Expected: FAIL with undefined method.

- [ ] **Step 3: Implement method**

Add to Article model:

```ruby
def keywords_for_seo
  tags = Array(metadata && metadata['hashtags']).map { |t| t.to_s.sub(/^#/, '') }
  tags.presence || [category]
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker compose exec -T web bundle exec rspec spec/models/article_spec.rb --no-color 2>&1 | tail -10`
Expected: All examples pass.

- [ ] **Step 5: Commit**

```bash
cd /home/q/victory
git add spec/models/article_spec.rb app/models/article.rb
GIT_AUTHOR_NAME="Claude Code" GIT_AUTHOR_EMAIL="noreply@anthropic.com" \
  git commit -m "feat(article): keywords_for_seo — hashtags from metadata with category fallback"
```

---

## Task 7: BlogHelper#article_author_schema

**Files:**
- Modify or Create: `app/helpers/blog_helper.rb`
- Test: `spec/helpers/blog_helper_spec.rb`

- [ ] **Step 1: Check whether BlogHelper exists**

Run: `ls /home/q/victory/app/helpers/blog_helper.rb 2>&1`
- If exists: read first 20 lines to understand existing module
- If not: will create new file

- [ ] **Step 2: Write failing test**

Create or edit `spec/helpers/blog_helper_spec.rb`:

```ruby
require 'rails_helper'

RSpec.describe BlogHelper, type: :helper do
  describe '#article_author_schema' do
    it 'returns Person reference when author has agent_slug' do
      author = build_stubbed(:user, agent_slug: 'ivan-petrov')
      article = build_stubbed(:article, author: author)

      expect(helper.article_author_schema(article)).to eq(
        '@type' => 'Person',
        '@id' => "#{AgencyInfo::WEBSITE_URL}/agents/ivan-petrov#person"
      )
    end

    it 'returns Organization reference when no author' do
      article = build_stubbed(:article, author: nil)

      expect(helper.article_author_schema(article)).to eq(
        '@type' => 'Organization',
        '@id' => "#{AgencyInfo::WEBSITE_URL}/#agent"
      )
    end

    it 'returns Organization reference when author has no agent_slug' do
      author = build_stubbed(:user, agent_slug: nil)
      article = build_stubbed(:article, author: author)

      expect(helper.article_author_schema(article)).to eq(
        '@type' => 'Organization',
        '@id' => "#{AgencyInfo::WEBSITE_URL}/#agent"
      )
    end
  end
end
```

Note: requires FactoryBot factories for `:user` and `:article`. If missing — check `spec/factories/` and skip test (manual verification fallback in Step 4).

- [ ] **Step 3: Run test to verify it fails**

Run: `docker compose exec -T web bundle exec rspec spec/helpers/blog_helper_spec.rb --no-color 2>&1 | tail -10`
Expected: FAIL with undefined method или missing factory.

If missing factories — skip to Step 4, will verify manually via `bin/rails runner`.

- [ ] **Step 4: Implement helper**

Edit `app/helpers/blog_helper.rb` (create if doesn't exist):

```ruby
# frozen_string_literal: true

module BlogHelper
  # Author Schema.org reference для article JSON-LD.
  # Если автор привязан и имеет agent_slug → Person reference.
  # Иначе — fallback на Organization @id (existing global agent entity).
  def article_author_schema(article)
    if article.author&.agent_slug.present?
      {
        '@type' => 'Person',
        '@id' => "#{AgencyInfo::WEBSITE_URL}/agents/#{article.author.agent_slug}#person"
      }
    else
      {
        '@type' => 'Organization',
        '@id' => "#{AgencyInfo::WEBSITE_URL}/#agent"
      }
    end
  end
end
```

- [ ] **Step 5: Verify (auto-test or manual)**

If factories present: `docker compose exec -T web bundle exec rspec spec/helpers/blog_helper_spec.rb` → PASS.

Else manual в Rails runner:

```bash
docker compose exec -T web bin/rails runner '
include BlogHelper
include AgencyInfo

a1 = Article.new(author: User.new(agent_slug: "test-slug"))
puts article_author_schema(a1).inspect
# Expect: {"@type"=>"Person", "@id"=>"https://victory62.org/agents/test-slug#person"}

a2 = Article.new(author: nil)
puts article_author_schema(a2).inspect
# Expect: {"@type"=>"Organization", "@id"=>"https://victory62.org/#agent"}
'
```

- [ ] **Step 6: Commit**

```bash
cd /home/q/victory
git add app/helpers/blog_helper.rb
git add spec/helpers/blog_helper_spec.rb 2>/dev/null || true
GIT_AUTHOR_NAME="Claude Code" GIT_AUTHOR_EMAIL="noreply@anthropic.com" \
  git commit -m "feat(blog): article_author_schema helper — Person ref or Organization fallback"
```

---

## Task 8: Extend `_jsonld_article.html.erb` with new fields

**Files:**
- Read: `app/views/shared/_jsonld_article.html.erb` (to identify insertion point)
- Modify: `app/views/shared/_jsonld_article.html.erb`

- [ ] **Step 1: Read existing partial**

```bash
cd /home/q/victory && head -60 app/views/shared/_jsonld_article.html.erb
```

Identify the JSON hash literal that builds the Article schema.

- [ ] **Step 2: Add new fields to JSON-LD hash**

Inside the existing hash (or merge after main fields), add:

```erb
'wordCount' => @article.word_count,
'timeRequired' => @article.iso_duration,
'articleSection' => @article.category,
'keywords' => @article.keywords_for_seo.join(', '),
'author' => article_author_schema(@article)
```

If partial uses `local_assigns[:article]` (not `@article`) — adapt variable name accordingly.

- [ ] **Step 3: Verify rendering на sample article**

Get a published article slug:

```bash
SLUG=$(docker compose exec -T web bin/rails runner 'puts Article.public_facing.first.slug' 2>&1 | tail -1)
curl -s "http://localhost:3000/blog/$SLUG" | grep -oE '"wordCount":[0-9]+|"timeRequired":"PT[^"]+|"articleSection":"[^"]+|"keywords":"[^"]+|"author":\{[^}]+\}' | sort -u
```

Expected: 5 lines printed, one для each new field.

- [ ] **Step 4: Validate JSON-LD parses cleanly**

```bash
curl -s "http://localhost:3000/blog/$SLUG" | python3 -c "
import re, json, sys
html = sys.stdin.read()
blocks = re.findall(r'<script type=\"application/ld\+json\">\s*(.+?)\s*</script>', html, re.DOTALL)
for i, b in enumerate(blocks):
    try:
        json.loads(b)
        print(f'  [{i}] OK')
    except json.JSONDecodeError as e:
        print(f'  [{i}] INVALID: {e}')
"
```

Expected: all blocks `OK`. No `INVALID`.

- [ ] **Step 5: Commit**

```bash
cd /home/q/victory
git add app/views/shared/_jsonld_article.html.erb
GIT_AUTHOR_NAME="Claude Code" GIT_AUTHOR_EMAIL="noreply@anthropic.com" \
  git commit -m "feat(seo): _jsonld_article — add wordCount, timeRequired, articleSection, keywords, author"
```

---

## Task 9: Seo::HowToExtractor service + test

**Files:**
- Create: `app/services/seo/how_to_extractor.rb`
- Create: `spec/services/seo/how_to_extractor_spec.rb`

- [ ] **Step 1: Write failing service test**

Create `spec/services/seo/how_to_extractor_spec.rb`:

```ruby
require 'rails_helper'

RSpec.describe Seo::HowToExtractor do
  describe '#extractable?' do
    it 'returns false when fewer than 3 <li> in <ol>' do
      html = '<ol><li>Step one</li><li>Step two</li></ol>'
      expect(described_class.new(html).extractable?).to be(false)
    end

    it 'returns true when 3+ <li> in <ol>' do
      html = '<ol><li>One</li><li>Two</li><li>Three</li></ol>'
      expect(described_class.new(html).extractable?).to be(true)
    end

    it 'returns false когда нет <ol> вообще' do
      html = '<p>Just paragraphs, no list.</p>'
      expect(described_class.new(html).extractable?).to be(false)
    end
  end

  describe '#steps' do
    it 'extracts name from <strong> when present' do
      html = '<ol><li><strong>Запросить документы</strong> у собственника</li>' \
             '<li><strong>Проверить ЕГРН</strong> онлайн</li>' \
             '<li><strong>Сверить паспорт</strong> с выпиской</li></ol>'

      steps = described_class.new(html).steps

      expect(steps[0]).to include('@type' => 'HowToStep', 'position' => 1, 'name' => 'Запросить документы')
      expect(steps[0]['text']).to eq('у собственника')
    end

    it 'falls back to "Шаг N" when no <strong>' do
      html = '<ol><li>Action one</li><li>Action two</li><li>Action three</li></ol>'
      steps = described_class.new(html).steps

      expect(steps[0]['name']).to eq('Шаг 1')
      expect(steps[0]['text']).to eq('Action one')
    end

    it 'truncates step text к 500 chars' do
      long = 'x' * 700
      html = "<ol><li>#{long}</li><li>second</li><li>third</li></ol>"
      steps = described_class.new(html).steps

      expect(steps[0]['text'].length).to be <= 500
    end

    it 'caps at MAX_STEPS = 12' do
      items = (1..20).map { |i| "<li>Step #{i}</li>" }.join
      html = "<ol>#{items}</ol>"

      expect(described_class.new(html).steps.size).to eq(12)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `docker compose exec -T web bundle exec rspec spec/services/seo/how_to_extractor_spec.rb --no-color 2>&1 | tail -10`
Expected: FAIL with `uninitialized constant Seo::HowToExtractor`.

- [ ] **Step 3: Implement service**

Create `app/services/seo/how_to_extractor.rb`:

```ruby
# frozen_string_literal: true

module Seo
  # Извлекает шаги для Schema.org HowTo из article body HTML.
  # Конвенция: автор пишет шаги как
  #   <ol>
  #     <li><strong>Заголовок шага</strong> описание текстом...</li>
  #     ...
  #   </ol>
  # <strong> — опциональная метка для HowToStep.name; если её нет, берём
  # "Шаг N". Только когда extractable? == true (≥ MIN_STEPS шагов).
  class HowToExtractor
    MIN_STEPS = 3
    MAX_STEPS = 12

    def initialize(html)
      @html = html.to_s
    end

    def extractable?
      steps.size >= MIN_STEPS
    end

    def steps
      @steps ||= Nokogiri::HTML.fragment(@html).css('ol > li').first(MAX_STEPS).map.with_index(1) do |li, i|
        name = li.css('strong, b').first&.text&.strip&.presence
        full_text = li.text.strip
        body_text = name ? full_text.delete_prefix(name).strip.presence : nil
        {
          '@type' => 'HowToStep',
          'position' => i,
          'name' => name || "Шаг #{i}",
          'text' => (body_text || full_text).truncate(500)
        }
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `docker compose exec -T web bundle exec rspec spec/services/seo/how_to_extractor_spec.rb --no-color 2>&1 | tail -10`
Expected: 5 examples, 0 failures.

- [ ] **Step 5: Verify on real article**

```bash
docker compose exec -T web bin/rails runner '
article = Article.find_by(category: "guides")
ex = Seo::HowToExtractor.new(article.body_html)
puts "extractable=#{ex.extractable?} steps=#{ex.steps.size}"
puts ex.steps.first(2).inspect
'
```

Expected: `extractable=true steps=N` (N ≥ 3) with sample steps printed.

If `extractable=false` — that article's body doesn't have `<ol>` structure. Document in audit, move to Task 10 anyway (partial will silently не-render).

- [ ] **Step 6: Commit**

```bash
cd /home/q/victory
git add spec/services/seo/how_to_extractor_spec.rb app/services/seo/how_to_extractor.rb
GIT_AUTHOR_NAME="Claude Code" GIT_AUTHOR_EMAIL="noreply@anthropic.com" \
  git commit -m "feat(seo): HowToExtractor service — parse <ol> steps for Schema.org HowTo"
```

---

## Task 10: _jsonld_how_to partial + wire in blog/show

**Files:**
- Create: `app/views/shared/_jsonld_how_to.html.erb`
- Modify: `app/views/blog/show.html.erb`

- [ ] **Step 1: Create partial**

Write `app/views/shared/_jsonld_how_to.html.erb`:

```erb
<%# Schema.org HowTo — emit ТОЛЬКО когда article body содержит structured
    ordered list of >= 3 items. Я. + Google активируют accordion-style
    rich snippet в SERP. locals: article, extractor (Seo::HowToExtractor). %>
<% if extractor.extractable? %>
<script type="application/ld+json">
<%= raw({
  '@context' => 'https://schema.org',
  '@type' => 'HowTo',
  'name' => article.title,
  'description' => article.short_excerpt,
  'totalTime' => article.iso_duration,
  'image' => (article.cover_image.attached? ? url_for(article.cover_image.variant(:hero)) : nil),
  'step' => extractor.steps
}.compact.to_json) %>
</script>
<% end %>
```

- [ ] **Step 2: Read blog/show.html.erb to find content_for :head block**

```bash
cd /home/q/victory && grep -n 'content_for :head\|jsonld_article' app/views/blog/show.html.erb | head
```

Identify где rendered `jsonld_article` partial — там же добавляем HowTo render.

- [ ] **Step 3: Wire HowTo render conditionally on category=guides**

Edit `app/views/blog/show.html.erb`. Inside `content_for :head do ... end` block (or right after existing `render 'jsonld_article'`), add:

```erb
<% if @article.category == 'guides' %>
  <% how_to_extractor = Seo::HowToExtractor.new(@article.body_html) %>
  <%= render 'shared/jsonld_how_to', article: @article, extractor: how_to_extractor %>
<% end %>
```

- [ ] **Step 4: Verify on real guides article**

```bash
SLUG=$(docker compose exec -T web bin/rails runner 'puts Article.where(category: "guides").first.slug' 2>&1 | tail -1)
echo "Testing /blog/$SLUG"
curl -s "http://localhost:3000/blog/$SLUG" | grep -c '"@type":"HowTo"'
```

Expected: `1` (один HowTo block emitted). If `0` — check whether extractable? returns true (article may not have `<ol>` structure). 

```bash
curl -s "http://localhost:3000/blog/$SLUG" | python3 -c "
import re, json, sys
html = sys.stdin.read()
for b in re.findall(r'<script type=\"application/ld\+json\">\s*(.+?)\s*</script>', html, re.DOTALL):
    d = json.loads(b)
    if d.get('@type') == 'HowTo':
        print(f'steps={len(d[\"step\"])} name={d[\"name\"]}')
"
```

Expected: `steps=N name=<title>`.

- [ ] **Step 5: Verify non-guides articles don't emit HowTo**

```bash
NEWS_SLUG=$(docker compose exec -T web bin/rails runner 'puts Article.where(category: "news").public_facing.first.slug' 2>&1 | tail -1)
curl -s "http://localhost:3000/blog/$NEWS_SLUG" | grep -c '"@type":"HowTo"'
```

Expected: `0`.

- [ ] **Step 6: Validate JSON-LD on guides page**

```bash
curl -s "http://localhost:3000/blog/$SLUG" | python3 -c "
import re, json, sys
html = sys.stdin.read()
for i, b in enumerate(re.findall(r'<script type=\"application/ld\+json\">\s*(.+?)\s*</script>', html, re.DOTALL)):
    try:
        json.loads(b)
        print(f'  [{i}] OK')
    except json.JSONDecodeError as e:
        print(f'  [{i}] INVALID: {e}')
"
```

Expected: all `OK`.

- [ ] **Step 7: Commit**

```bash
cd /home/q/victory
git add app/views/shared/_jsonld_how_to.html.erb app/views/blog/show.html.erb
GIT_AUTHOR_NAME="Claude Code" GIT_AUTHOR_EMAIL="noreply@anthropic.com" \
  git commit -m "feat(seo): HowTo Schema for guides — accordion rich snippet in SERP"
```

---

## Task 11: BlogController#category — CATEGORY_META + extended action

**Files:**
- Modify: `app/controllers/blog_controller.rb`

- [ ] **Step 1: Read current controller**

```bash
cd /home/q/victory && cat app/controllers/blog_controller.rb
```

Identify `#category` action (existing).

- [ ] **Step 2: Add CATEGORY_META constant**

Edit `app/controllers/blog_controller.rb` — inside class, before existing actions:

```ruby
CATEGORY_META = {
  'market' => {
    h1: 'Аналитика рынка недвижимости',
    description: 'Свежие обзоры цен, динамики спроса и тренды рынка недвижимости Рязани, Москвы и СПб от АН «Виктори». Еженедельные дайджесты от экспертов с 18-летним опытом.',
    intro: 'Каждую неделю — обзор движения цен, доступности ипотеки и локальных трендов. Базируется на нашей закрытой базе сделок.'
  },
  'guides' => {
    h1: 'Гайды по покупке недвижимости',
    description: 'Пошаговые руководства: как проверить квартиру, оформить ипотеку, выбрать район. Чек-листы и инструкции от риелторов АН «Виктори».',
    intro: 'Подробные инструкции от наших агентов — без воды, по делу.'
  },
  'news' => {
    h1: 'Новости рынка недвижимости',
    description: 'Срочные новости рынка недвижимости, изменения ключевой ставки ЦБ, банковские программы ипотеки. Обновляется ежедневно.',
    intro: 'Срочные новости с комментариями от экспертов АН «Виктори».'
  },
  'investment' => {
    h1: 'Инвестиции в недвижимость',
    description: 'Доходные стратегии в недвижимости Рязани: аренда, флиппинг, новостройки. Анализ окупаемости от инвест-аналитиков АН «Виктори».',
    intro: 'Стратегии для инвесторов: что покупать, как считать доходность.'
  },
  'mortgage' => {
    h1: 'Ипотека — программы и калькуляторы',
    description: 'Актуальные ипотечные программы банков-партнёров АН «Виктори», расчёт платежей, льготные программы (семейная, IT, дальневосточная).',
    intro: 'Все ипотечные программы Сбера, ВТБ, Альфы и др. в одном месте.'
  }
}.freeze
```

- [ ] **Step 3: Replace `#category` action**

In same file, replace existing `def category ... end` with:

```ruby
def category
  @category = params[:category]
  return redirect_to(blog_path, alert: 'Категория не найдена') unless Article::CATEGORIES.include?(@category)

  meta = CATEGORY_META.fetch(@category)
  @h1 = meta[:h1]
  @meta_description = meta[:description]
  @intro = meta[:intro]
  @articles = Article.public_facing
                     .where(category: @category)
                     .page(params[:page])
                     .per(@per_page || 12)
  add_breadcrumb 'Блог', blog_path
  add_breadcrumb @h1
  render :category
end
```

- [ ] **Step 4: Verify controller smoke (won't render yet — view не существует)**

```bash
curl -sI "http://localhost:3000/blog/category/guides" | head -3
```

Expected: HTTP 500 (template missing) OR 200 if existing render :index fallback still works.

If 500 with `ActionView::MissingTemplate: Missing template blog/category` — это OK, мы создадим view в Task 12.

- [ ] **Step 5: Verify invalid category redirects**

```bash
curl -sI "http://localhost:3000/blog/category/invalid" | head -3
```

Expected: HTTP 302 redirect to /blog.

- [ ] **Step 6: Commit**

```bash
cd /home/q/victory
git add app/controllers/blog_controller.rb
GIT_AUTHOR_NAME="Claude Code" GIT_AUTHOR_EMAIL="noreply@anthropic.com" \
  git commit -m "feat(blog): BlogController#category — CATEGORY_META + dedicated view render"
```

---

## Task 12: blog/category.html.erb view

**Files:**
- Create: `app/views/blog/category.html.erb`

- [ ] **Step 1: Read existing index.html.erb (для structure reuse)**

```bash
cd /home/q/victory && cat app/views/blog/index.html.erb
```

Note structure: how breadcrumb rendered, how articles rendered (probably uses `_article_card` partial).

- [ ] **Step 2: Create category.html.erb**

Write `app/views/blog/category.html.erb`:

```erb
<% content_for :title, "#{@h1} — АН Виктори" %>
<% content_for :seo_description, @meta_description %>

<%# CollectionPage JSON-LD — links to ItemList of articles в категории.
    Я./Google parsing: знает что это hub-page topical cluster'a. %>
<% content_for :head do %>
<script type="application/ld+json">
<%= raw({
  '@context' => 'https://schema.org',
  '@type' => 'CollectionPage',
  'name' => @h1,
  'description' => @meta_description,
  'url' => blog_category_url(category: @category),
  'isPartOf' => { '@id' => "#{AgencyInfo::WEBSITE_URL}/#website" },
  'mainEntity' => {
    '@type' => 'ItemList',
    'numberOfItems' => @articles.total_count,
    'itemListElement' => @articles.each_with_index.map { |a, i|
      { '@type' => 'ListItem', 'position' => i + 1, 'url' => blog_post_url(slug: a.slug), 'name' => a.title }
    }
  }
}.to_json) %>
</script>
<% end %>

<%= render 'shared/breadcrumb', items: [
  ['Главная', root_path],
  ['Блог', blog_path],
  [@h1, nil]
] %>

<section class="px-6 lg:px-12 py-12 lg:py-16 bg-background">
  <div class="max-w-7xl mx-auto">
    <p class="text-sm tracking-[0.4em] text-muted-foreground mb-4">БЛОГ · <%= @category.upcase %></p>
    <h1 class="text-4xl md:text-5xl lg:text-6xl font-light tracking-wider text-foreground mb-6 leading-tight">
      <%= @h1 %>
    </h1>
    <p class="text-base text-muted-foreground leading-relaxed mb-12 max-w-3xl"><%= @intro %></p>

    <%# Category nav-bar — cross-link discovery для Я./Google + UX %>
    <nav class="flex flex-wrap gap-3 mb-12 text-xs tracking-[0.3em]" aria-label="Категории блога">
      <%= link_to 'ВСЕ', blog_path,
                  class: 'px-4 py-2 border border-border text-foreground hover:bg-foreground hover:text-background transition-colors' %>
      <% Article::CATEGORIES.each do |cat| %>
        <%= link_to cat.upcase,
                    blog_category_path(category: cat),
                    class: "px-4 py-2 border border-border #{cat == @category ? 'bg-foreground text-background' : 'text-foreground hover:bg-foreground hover:text-background'} transition-colors" %>
      <% end %>
    </nav>

    <% if @articles.any? %>
      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-8">
        <% @articles.each do |article| %>
          <%= render 'article_card', article: article %>
        <% end %>
      </div>

      <div class="mt-12 flex justify-center">
        <%= paginate @articles if respond_to?(:paginate) %>
      </div>
    <% else %>
      <div class="border border-border p-12 text-center">
        <p class="text-sm tracking-wider text-muted-foreground">
          Пока нет статей в этой категории. <%= link_to 'Все статьи →', blog_path, class: 'underline text-foreground' %>
        </p>
      </div>
    <% end %>
  </div>
</section>
```

- [ ] **Step 3: Verify rendering**

```bash
curl -sI "http://localhost:3000/blog/category/guides" | head -1
```

Expected: HTTP/1.1 200 OK.

- [ ] **Step 4: Verify content**

```bash
curl -s "http://localhost:3000/blog/category/guides" | grep -oE '<title>[^<]+|<h1[^>]*>[^<]+|"@type":"CollectionPage"|ВСЕ' | head -5
```

Expected:
- `<title>Гайды по покупке недвижимости — АН Виктори`
- `<h1 ...>Гайды по покупке недвижимости`
- `"@type":"CollectionPage"`
- `ВСЕ` (category nav-bar present)

- [ ] **Step 5: Verify JSON-LD parses cleanly**

```bash
curl -s "http://localhost:3000/blog/category/guides" | python3 -c "
import re, json, sys
html = sys.stdin.read()
for i, b in enumerate(re.findall(r'<script type=\"application/ld\+json\">\s*(.+?)\s*</script>', html, re.DOTALL)):
    try:
        d = json.loads(b)
        print(f'  [{i}] @type={d.get(\"@type\")} OK')
    except json.JSONDecodeError as e:
        print(f'  [{i}] INVALID: {e}')
"
```

Expected: includes `@type=CollectionPage OK`. No INVALID.

- [ ] **Step 6: Commit**

```bash
cd /home/q/victory
git add app/views/blog/category.html.erb
GIT_AUTHOR_NAME="Claude Code" GIT_AUTHOR_EMAIL="noreply@anthropic.com" \
  git commit -m "feat(blog): /blog/category/:slug dedicated view — CollectionPage JSON-LD + nav-bar"
```

---

## Task 13: blog/index.html.erb — category nav-bar

**Files:**
- Modify: `app/views/blog/index.html.erb`

- [ ] **Step 1: Read existing index.html.erb**

```bash
cd /home/q/victory && cat app/views/blog/index.html.erb
```

Identify section/grid где articles rendered. Nav-bar добавляем перед grid.

- [ ] **Step 2: Add category nav-bar**

Insert into `app/views/blog/index.html.erb` перед article grid:

```erb
<%# Category nav — internal linking для Я./Google topical cluster discovery.
    Mirrors nav-bar в blog/category view. %>
<nav class="flex flex-wrap gap-3 mb-12 text-xs tracking-[0.3em]" aria-label="Категории блога">
  <%= link_to 'ВСЕ', blog_path,
              class: 'px-4 py-2 border border-border bg-foreground text-background' %>
  <% Article::CATEGORIES.each do |cat| %>
    <%= link_to cat.upcase,
                blog_category_path(category: cat),
                class: 'px-4 py-2 border border-border text-foreground hover:bg-foreground hover:text-background transition-colors' %>
  <% end %>
</nav>
```

(Note: «ВСЕ» уже active when on /blog index — bg-foreground стиль.)

- [ ] **Step 3: Verify**

```bash
curl -s "http://localhost:3000/blog" | grep -oE 'aria-label="Категории блога"|>ВСЕ<|>MARKET<|>GUIDES<|>NEWS<|>INVESTMENT<|>MORTGAGE<' | sort -u
```

Expected:
```
aria-label="Категории блога"
>GUIDES<
>INVESTMENT<
>MARKET<
>MORTGAGE<
>NEWS<
>ВСЕ<
```

- [ ] **Step 4: Commit**

```bash
cd /home/q/victory
git add app/views/blog/index.html.erb
GIT_AUTHOR_NAME="Claude Code" GIT_AUTHOR_EMAIL="noreply@anthropic.com" \
  git commit -m "feat(blog): category nav-bar on /blog index — internal linking discovery"
```

---

## Task 14: sitemap-pages.xml — 5 category URLs

**Files:**
- Modify: `app/views/sitemap/pages.xml.erb`

- [ ] **Step 1: Read sitemap structure**

```bash
cd /home/q/victory && grep -n 'blog_url\|articles_mod' app/views/sitemap/pages.xml.erb | head
```

Identify где `blog_url` entry — там же добавим category URLs (после).

- [ ] **Step 2: Append 5 category entries**

Edit `app/views/sitemap/pages.xml.erb` — after the `[blog_url, ...]` entry (before the closing of static pages block, OR after the static loop), добавить:

```erb
<%# Article category hub-pages — internal authority distribution. Lastmod =
    max(Article.updated_at) в категории; если пусто — skip URL (soft-404
    avoidance — не индексируем empty hub-pages). %>
<% Article::CATEGORIES.each do |cat| %>
  <% latest = Article.public_facing.where(category: cat).maximum(:updated_at) %>
  <% next unless latest %>
  <url>
    <loc><%= blog_category_url(category: cat) %></loc>
    <lastmod><%= latest.iso8601 %></lastmod>
    <changefreq>weekly</changefreq>
    <priority>0.7</priority>
  </url>
<% end %>
```

- [ ] **Step 3: Verify**

```bash
curl -s "http://localhost:3000/sitemap-pages.xml" | grep -c '/blog/category/'
```

Expected: count = число категорий with ≥ 1 article (как минимум `news` есть — 9 articles; `guides` 1; `market` 1; так что 3+).

```bash
curl -s "http://localhost:3000/sitemap-pages.xml" | grep -oE '/blog/category/[a-z]+'
```

Expected: 3-5 unique URLs.

- [ ] **Step 4: Commit**

```bash
cd /home/q/victory
git add app/views/sitemap/pages.xml.erb
GIT_AUTHOR_NAME="Claude Code" GIT_AUTHOR_EMAIL="noreply@anthropic.com" \
  git commit -m "feat(sitemap): /blog/category/:cat URLs with dynamic lastmod"
```

---

## Task 15: Final verification + Y.Webmaster recrawl submit

**Files:** (no edits, verification + ops)

- [ ] **Step 1: Smoke 10 URLs final pass**

```bash
cd /home/q/victory
for url in / /properties /about /reviews /blog /blog/category/guides /blog/category/news /cases /valuations/new /kupit/kvartira /sitemap-news.xml /sitemap-pages.xml; do
  code=$(curl -sI -o /dev/null -w "%{http_code}" "http://localhost:3000$url?n=$RANDOM")
  printf '  %-45s %s\n' "$url" "$code"
done
```

Expected: все 200 (kроме /sitemap-news.xml which is 200, и /sitemap-pages.xml which is 200).

- [ ] **Step 2: ERB-leak check**

```bash
for url in / /blog /blog/category/guides /blog/<guides-slug-replace>; do
  leak=$(curl -s "http://localhost:3000$url" | grep -cE '<%[^/]|^[^<]*%>')
  printf '  %-40s leak hits: %s\n' "$url" "$leak"
done
```

Expected: all `leak hits: 0`.

- [ ] **Step 3: validator.schema.org spot-checks**

For 3 key URLs (/blog/<guides-slug>, /blog/category/guides, /blog/<news-slug>):

```bash
for url in /blog/category/guides /blog/category/news; do
  echo "--- $url ---"
  curl -s "http://localhost:3000$url" | python3 -c "
import re, json, sys
html = sys.stdin.read()
for i, b in enumerate(re.findall(r'<script type=\"application/ld\+json\">\s*(.+?)\s*</script>', html, re.DOTALL)):
    try:
        d = json.loads(b)
        types = [d.get('@type')] if isinstance(d, dict) else [x.get('@type') for x in d]
        print(f'  [{i}] OK types={types}')
    except json.JSONDecodeError as e:
        print(f'  [{i}] INVALID: {e}')
"
done
```

Expected: all OK, no INVALID, expected @types appear (NewsArticle on blog/show, CollectionPage on category, HowTo on guides article).

- [ ] **Step 4: Y.Webmaster recrawl submit для новых URLs**

```bash
docker compose exec -T web bundle exec rake yandex:webmaster:recrawl:critical 2>&1 | grep -vE 'unknown OID|Bundler|/tmp/bundler' | tail
```

Plus individually 5 new category URLs:

```bash
for cat in market guides news investment mortgage; do
  docker compose exec -T web bundle exec rake "yandex:webmaster:recrawl[https://victory62.org/blog/category/$cat]" 2>&1 | tail -3
done
```

Expected: each submission successful, quota decrements; some categories may return error if no articles (skipped в sitemap → 404 — engineer adjusts if needed).

- [ ] **Step 5: Push to origin**

```bash
cd /home/q/victory
git push origin claude/currency-converter-app-9Ljw6 2>&1 | tail -3
```

Expected: successful push, no rejection.

- [ ] **Step 6: Verify production picks up changes (within ~30s of push if auto-deploy)**

```bash
sleep 30
curl -sI 'https://victory62.org/blog/category/guides' | head -1
curl -s 'https://victory62.org/blog/category/guides' | grep -oE '<h1[^>]+>[^<]+' | head -1
```

Expected: HTTP/2 200; h1 includes "Гайды по покупке недвижимости".

Если staging/prod deploy ручной — пропустить, скоммитов достаточно.

---

## Self-Review

After writing the complete plan, look at the spec with fresh eyes and check the plan against it.

**1. Spec coverage:**
- Sub-system 1 (CWV audit) → Tasks 1, 2, 3, 4 ✅
- Sub-system 2 (Article enrichment) → Tasks 5, 6, 7, 8 ✅
- Sub-system 3 (HowTo Schema) → Tasks 9, 10 ✅
- Sub-system 4 (Hub pages) → Tasks 11, 12, 13, 14 ✅
- Final verification + Y.recrawl → Task 15 ✅
- All DoD items from spec addressed in tasks ✅

**2. Placeholder scan:**
- Task 2-4 reference "from audit doc" — acceptable since Task 1 produces concrete data
- All code blocks have actual content
- No "TBD" / "TODO" / "implement later" in non-task-2-4 places
- Task 2-4 fix code zaвисит от audit — это data-driven, не placeholder

**3. Type consistency:**
- `Article#word_count` used in Task 5 (define), Task 6 (consume), Task 8 (consume in partial) ✅
- `Article#iso_duration` used in Task 5 (define), Task 10 (consume) ✅
- `Seo::HowToExtractor` defined in Task 9, used in Task 10 ✅
- `BlogHelper#article_author_schema` defined Task 7, used Task 8 ✅
- `CATEGORY_META` defined Task 11, consumed Task 11 (same task), referenced Task 12 view via instance vars ✅
- `blog_category_url(category:)` route helper used in Tasks 12, 13, 14 ✅

All consistent.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-19-seo-tech-ctr-bundle.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. Best для multi-task plans where каждая task has clear in/out.

**2. Inline Execution** — Execute tasks в этой session using executing-plans, batch execution with checkpoints. Best когда want continuous context.

**Which approach?**
