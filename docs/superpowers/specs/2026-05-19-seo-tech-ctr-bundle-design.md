# SEO Tech/CTR bundle — design (2026-05-19)

> **Branch:** `claude/currency-converter-app-9Ljw6`
> **Origin:** /superpowers:brainstorming triggered after Y.Webmaster API integration revealed CTR=0 across 12 indexed queries despite top-3 positions for some.
> **Status:** Design approved by user (delegated self-check). Ready for implementation planning via `superpowers:writing-plans`.

---

## Context

После 11 SEO-коммитов 18.05.2026 (Y.Webmaster API, recrawl pipeline, favicon, photo-slider, IndexNow, sitemap-news visible+in_category) **technical SEO ~98% complete**. Дальнейший рост требует другой природы работы.

**Y.Webmaster API snapshot (18.05.2026):**
- SQI = 10 (stable 4 days, newborn baseline)
- 12 unique queries with показы, **0 кликов на всех 12** — биggest deferred opportunity
- Top brand position: `виктори агентство` pos=3 (rich snippet potential)
- HF target: `купить квартиру в рязани` pos=18 (out of SERP fold)
- 1 active diagnostic: `FAVICON_PROBLEM` (RECOMMENDATION) — Y. ещё не подхватила обновлённый favicon
- Recrawl quota: 11/150 used today (10 critical URLs + 1 favicon)

**Strategic observations:**
- CTR > median triggers behavioral ranking boost (verified Y. factor)
- CWV в ranking factor since 2024 — мы никогда не измеряли
- Long-tail capture от weekly_digest validates Pillar 3 (AI×human conveyor — `вестник банка россии` pos=4 за 5 дней)
- Topical authority needs hub-pages (Я. ценит site structure where related content cross-linked)

**Sprint goal:** усилить **on-site technical signals** (CWV, Schema sophistication, internal linking topology) для:
1. CTR boost через rich snippets (HowTo, enhanced Article schema)
2. Ranking boost через CWV improvements
3. Long-tail capture через hub-pages
4. Internal authority distribution через cross-linking

---

## Approach — Sequential data-first (A)

```
CWV audit (data) → Article enrichment (foundation) → HowTo Schema (additive) → Hub pages (topology)
```

Reasoning:
1. **CWV audit FIRST** — data informs другие решения. Если LCP > 4с на /blog/show — hub-pages design должен учесть.
2. **Article enrichment второй** — small additive change, foundation для HowTo (uses `Article#iso_duration` reading_time).
3. **HowTo Schema третий** — depends on Article enrichment via `totalTime` field.
4. **Hub pages последний** — самый большой, использует все предыдущие.

---

## Sub-system 1 — CWV Audit

**Goal.** Замерить Core Web Vitals на 10 critical URLs через Chrome DevTools MCP, document findings, пофиксить top-3 worst issues в рамках бюджета. Длинные fixes (LCP > 4s consistently) — defer в отдельный sprint.

**Tool:** `mcp__plugin_chrome-devtools-mcp_chrome-devtools__lighthouse_audit` + `__performance_start_trace` + `__performance_stop_trace`.

**Test pages:**
1. `/` — главная (LCP critical)
2. `/properties` — каталог index
3. `/properties/<active-slug>` — sample property show (hero slider!)
4. `/about` — slider 3 фото
5. `/reviews` — Yandex iframe + наша carousel
6. `/blog` — article index
7. `/blog/<recent-slug>` — sample article
8. `/kupit/kvartira` — type-only landing
9. `/kupit/kvartira/rayon/centr` — district с slider
10. `/valuations/new` — form (interactive!)

**Metrics + thresholds (per Я. ranking docs 2024):**
| Metric | Good | Needs work | Poor (penalty) |
|---|---|---|---|
| LCP | < 2.5s | 2.5-4s | > 4s |
| CLS | < 0.1 | 0.1-0.25 | > 0.25 |
| INP | < 200ms | 200-500ms | > 500ms |
| TTI | < 3.8s | 3.8-7.3s | > 7.3s |
| Speed Index | < 3.4s | 3.4-5.8s | > 5.8s |

**Output:** `.claude/docs/seo/cwv-audit-2026-05-19.md` со scores per page + ranked issues + concrete fix proposals.

**Likely candidates (предсказательно, до audit):**
- Photo-slider eager loading нескольких photos (только i=0 должна eager — проверить)
- Yandex Maps reviews iframe — render-blocking на /reviews
- Property images без responsive `srcset`/`sizes`
- Tailwind CSS purge — есть/нет
- Layout shift от lazy-loading without dimensions reservation

**Fix budget:** top-3 issues, ~2 часа fix work. Файлы которые скорее всего затронут:
- `app/views/shared/_photo_slider.html.erb` (eager-loading discipline)
- `app/views/shared/_yandex_reviews_widget.html.erb` (IntersectionObserver lazy iframe)
- `app/helpers/property_image_helper.rb` (responsive srcset audit)

---

## Sub-system 2 — Article enrichment

**Goal.** Расширить Schema.org Article JSON-LD четырьмя полями: `wordCount`, `timeRequired`, `author` Person reference, `articleSection`, `keywords`. Никакой миграции — computed methods.

**Article model additions** (`app/models/article.rb`):
```ruby
def word_count
  ActionView::Base.full_sanitizer.sanitize(body_html.to_s).split.size
end

def reading_time_minutes
  return 1 if word_count.zero?
  (word_count / 200.0).ceil  # 200 wpm averaged Russian reading
end

def iso_duration
  "PT#{reading_time_minutes}M"  # ISO 8601 — "PT5M"
end

def keywords_for_seo
  tags = Array(metadata && metadata['hashtags']).map { |t| t.to_s.sub(/^#/, '') }
  tags.presence || [category]
end
```

**JSON-LD additions** (`app/views/shared/_jsonld_article.html.erb`):
```ruby
{
  'wordCount' => @article.word_count,
  'timeRequired' => @article.iso_duration,
  'articleSection' => @article.category,
  'keywords' => @article.keywords_for_seo.join(', '),
  'author' => article_author_schema(@article)
}.compact
```

**Author linkage:**
- Если `Article.author_id` + author has `agent_slug` → emit `{"@type": "Person", "@id": "https://victory62.org/agents/<slug>#person"}` (reference, не duplicate)
- Иначе fallback — emit Organization @id reference (uses existing `_jsonld_agent` @id)

Helper:
```ruby
# app/helpers/blog_helper.rb (or wherever appropriate)
def article_author_schema(article)
  if article.author&.agent_slug.present?
    { '@type' => 'Person', '@id' => "#{AgencyInfo::WEBSITE_URL}/agents/#{article.author.agent_slug}#person" }
  else
    { '@type' => 'Organization', '@id' => "#{AgencyInfo::WEBSITE_URL}/#agent" }
  end
end
```

**Files modified:**
- `app/models/article.rb` (4 computed methods)
- `app/views/shared/_jsonld_article.html.erb` (5 new JSON-LD fields)
- `app/helpers/blog_helper.rb` (new `article_author_schema` helper, create if absent)

**Files NEW:** none

**Verification:**
- `Article.first.word_count` returns int > 0
- `curl /blog/<slug> | grep -oE '"wordCount":[0-9]+'` → matches
- validator.schema.org parses без errors
- Article#timeRequired returns `PT<N>M` format

---

## Sub-system 3 — HowTo Schema для guides

**Goal.** Когда `Article.category == 'guides'` AND body содержит `<ol><li>` структуру ≥ 3 элементов — emit Schema.org HowTo parallel к Article JSON-LD. Активирует accordion-style rich snippet в Я./Google SERP.

**Service** (`app/services/seo/how_to_extractor.rb`, NEW):
```ruby
# frozen_string_literal: true

module Seo
  # Извлекает шаги для Schema.org HowTo из article body HTML.
  # Конвенция: автор пишет шаги как `<ol><li><strong>Заголовок шага</strong>
  # описание текстом...</li></ol>`. <strong> — опциональная metka для
  # HowToStep.name; если её нет, используем "Шаг N".
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

**Partial** (`app/views/shared/_jsonld_how_to.html.erb`, NEW):
```erb
<%# Schema.org HowTo — emit only when article body contains structured
    ordered list of >= 3 items. Я. activates accordion-style SERP rich
    snippet. locals: article, extractor (Seo::HowToExtractor instance) %>
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

**Wire** (`app/views/blog/show.html.erb`):
```erb
<% if @article.category == 'guides' %>
  <% extractor = Seo::HowToExtractor.new(@article.body_html) %>
  <%= render 'shared/jsonld_how_to', article: @article, extractor: extractor %>
<% end %>
```

**Files NEW:**
- `app/services/seo/how_to_extractor.rb`
- `app/views/shared/_jsonld_how_to.html.erb`

**Files modified:**
- `app/views/blog/show.html.erb` — conditional render HowTo (in content_for :head)

**Verification:**
- `Seo::HowToExtractor.new(Article.find_by(category: 'guides').body_html).extractable?` returns true
- `curl /blog/kak-proverit-kvartiru-pered-pokupkoy-cheklist-na` emits HowTo JSON-LD
- validator.schema.org: HowTo recognised, steps parsed
- Я.Webmaster ждём 1-2 недели для rich snippet activation

---

## Sub-system 4 — Hub pages (refinement of existing /blog/category)

**Goal.** `BlogController#category` уже существует (route `/blog/category/:category` → 200), но renders index view без category-specific Schema, без H1, без intro text. Refinement добавляет:
- Category-specific H1 + meta description + intro paragraph
- CollectionPage JSON-LD with ItemList of articles
- Category navigation bar в blog/index (cross-link discovery)
- Sitemap entries для 5 категорий

**Discovery:** Sub-system 4 — это **refinement не creation**. Route, controller action, view rendering уже работают.

**Controller** (`app/controllers/blog_controller.rb` — extend `#category`):
```ruby
CATEGORY_META = {
  'market' => {
    h1: 'Аналитика рынка недвижимости',
    description: 'Свежие обзоры цен, динамики спроса и тренды рынка ' \
                 'недвижимости Рязани, Москвы и СПб от АН «Виктори». ' \
                 'Еженедельные дайджесты от экспертов с 18-летним опытом.',
    intro: 'Каждую неделю — обзор движения цен, доступности ипотеки и ' \
           'локальных трендов. Базируется на нашей закрытой базе сделок.'
  },
  'guides' => {
    h1: 'Гайды по покупке недвижимости',
    description: 'Пошаговые руководства: как проверить квартиру, оформить ' \
                 'ипотеку, выбрать район. Чек-листы и инструкции от риелторов.',
    intro: 'Подробные инструкции от наших агентов — без воды, по делу.'
  },
  'news' => {
    h1: 'Новости рынка недвижимости',
    description: 'Срочные новости рынка недвижимости, изменения ключевой ' \
                 'ставки ЦБ, банковские программы ипотеки. Обновляется ежедневно.',
    intro: 'Срочные новости с комментариями от экспертов АН «Виктори».'
  },
  'investment' => {
    h1: 'Инвестиции в недвижимость',
    description: 'Доходные стратегии в недвижимости Рязани: аренда, флиппинг, ' \
                 'новостройки. Анализ окупаемости от инвест-аналитиков.',
    intro: 'Стратегии для инвесторов: что покупать, как считать доходность.'
  },
  'mortgage' => {
    h1: 'Ипотека — программы и калькуляторы',
    description: 'Актуальные ипотечные программы банков-партнёров АН ' \
                 '«Виктори», расчёт платежей, льготные программы.',
    intro: 'Все ипотечные программы Сбера, ВТБ, Альфы и др. в одном месте.'
  }
}.freeze

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

**View** (`app/views/blog/category.html.erb`, NEW):
- `content_for :title`, `:seo_description`
- DOM Breadcrumb (existing partial)
- H1 + intro paragraph
- Article cards grid (reuse `_article_card` partial)
- Pagination
- Category navigation bar (cross-link)
- `content_for :head do` block:
  - JSON-LD CollectionPage with mainEntity ItemList
  - canonical → `blog_category_url(@category)`

**JSON-LD shape:**
```json
{
  "@context": "https://schema.org",
  "@type": "CollectionPage",
  "name": "Гайды по покупке недвижимости",
  "description": "Пошаговые руководства...",
  "url": "https://victory62.org/blog/category/guides",
  "isPartOf": { "@id": "https://victory62.org/#website" },
  "mainEntity": {
    "@type": "ItemList",
    "numberOfItems": 7,
    "itemListElement": [
      { "@type": "ListItem", "position": 1, "url": "...", "name": "Как проверить квартиру..." }
    ]
  }
}
```

**Sitemap** (`app/views/sitemap/pages.xml.erb` — append after blog_url entry):
```erb
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

**Blog index nav-bar** (`app/views/blog/index.html.erb` — top of articles section):
```erb
<nav class="flex flex-wrap gap-3 mb-8 text-xs tracking-[0.3em]" aria-label="Категории блога">
  <%= link_to 'ВСЕ', blog_path, class: "px-4 py-2 border border-border text-foreground #{'bg-foreground text-background' if @category.blank?}" %>
  <% Article::CATEGORIES.each do |cat| %>
    <%= link_to t("article.categories.#{cat}", default: cat.humanize.upcase),
                blog_category_path(category: cat),
                class: "px-4 py-2 border border-border #{cat == @category ? 'bg-foreground text-background' : 'text-foreground hover:bg-foreground hover:text-background'}" %>
  <% end %>
</nav>
```

**Files NEW:**
- `app/views/blog/category.html.erb`

**Files modified:**
- `app/controllers/blog_controller.rb` — extend `#category` action + CATEGORY_META const
- `app/views/blog/index.html.erb` — добавить category nav-bar
- `app/views/sitemap/pages.xml.erb` — 5 category URLs (with dynamic lastmod)
- `config/locales/article.ru.yml` (if needed) — category display names

**Verification:**
- `curl /blog/category/guides` → 200 + H1 «Гайды по покупке недвижимости» + 1 article (id=2)
- `curl /sitemap-pages.xml | grep '/blog/category'` → 5 URLs (if all categories have ≥1 article)
- validator.schema.org parses CollectionPage без errors
- `curl /blog/category/invalid` → redirect to /blog with alert
- `curl /blog | grep 'category nav'` → renders all 5 category links

---

## Files inventory (sprint total)

**New (4):**
- `app/services/seo/how_to_extractor.rb`
- `app/views/shared/_jsonld_how_to.html.erb`
- `app/views/blog/category.html.erb`
- `.claude/docs/seo/cwv-audit-2026-05-19.md` (output, not committed initially)

**Modified (8+):**
- `app/models/article.rb` (Sub 2 — 4 methods)
- `app/views/shared/_jsonld_article.html.erb` (Sub 2 — 5 fields)
- `app/helpers/blog_helper.rb` (Sub 2 — article_author_schema helper, create if absent)
- `app/views/blog/show.html.erb` (Sub 3 — conditional HowTo render)
- `app/controllers/blog_controller.rb` (Sub 4 — CATEGORY_META + extended #category)
- `app/views/blog/index.html.erb` (Sub 4 — category nav-bar)
- `app/views/sitemap/pages.xml.erb` (Sub 4 — 5 category URLs)
- CWV-driven fixes (Sub 1 — depend on findings, predicted 2-3 files):
  - `app/views/shared/_photo_slider.html.erb`
  - `app/views/shared/_yandex_reviews_widget.html.erb`
  - `app/helpers/property_image_helper.rb` (or src image helper)

**Reuse:**
- `Article#published.visible.in_category` scopes (existing)
- `Article#short_excerpt` (existing)
- `Article.cover_image` attachment (existing)
- `User#agent_slug` column (existing, для Person @id reference)
- `AgencyInfo::WEBSITE_URL` constant
- `shared/_breadcrumb.html.erb` partial
- `add_breadcrumb` helper (used in controller)
- `Article.friendly` (FriendlyId — для slug lookups)

---

## Verification — sprint-level

1. **CWV audit doc** existed and contains scores per all 10 URLs, ranked issues
2. **Top-3 CWV fixes** applied и улучшение измерено (re-run Lighthouse на тех же URLs)
3. **Article model** — `Article.first.word_count > 0`, `iso_duration =~ /^PT\d+M$/`
4. **/blog/<slug>** JSON-LD contains: wordCount, timeRequired, author Person/Organization, articleSection, keywords
5. **/blog/<guides-slug>** emits HowTo JSON-LD parallel к Article (when body has `<ol>` ≥ 3 items)
6. **/blog/category/guides** renders dedicated category view with H1 «Гайды по покупке недвижимости», CollectionPage JSON-LD
7. **/blog index** shows category nav-bar with 6 links (ВСЕ + 5 categories)
8. **/sitemap-pages.xml** includes 5 category URLs (when categories have articles)
9. **validator.schema.org** parses все JSON-LD без errors на всех модифицированных pages
10. **Smoke 10 URLs** → все 200/302
11. **No ERB-leak** в HTML (grep for raw `<%` / `%>`)
12. **Y.Webmaster recrawl** submitted для всех 6 modified URLs (blog index + 5 categories) после deploy

---

## Out of scope (defer to later sprints)

- **Y.Дзен RSS submission** — user-side application (track B)
- **Я.Новости partner application** — user-side
- **VideoObject Schema** — no videos yet
- **Cyrillic slug experiment** — separate strategic test
- **External-link monitoring** — endpoint 404 пока, мало backlinks
- **Backlinks campaign** — user-side outreach (track C)
- **CaseStudy hub-page** — only 1 case study, premature; revisit after 5+
- **МСК/СПб landings контент** — separate content sprint (track B)
- **Article admin UI для steps json** — auto-extraction от Nokogiri достаточна для v1; если quality issues — add explicit `how_to_steps` jsonb column в v2

---

## Risks + mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| CWV audit показывает 10+ critical issues, top-3 budget недостаточен | Medium | Document everything, defer non-top-3 в separate spec, communicate scope-reduction to user |
| HowTo extractor false-positives на article с `<ol>` который не является step-list | Medium | MIN_STEPS=3 threshold + category=guides гард. Если still problematic — explicit `has_how_to: boolean` flag на Article |
| Hub-pages JSON-LD конфликтует с existing Schema on /blog (т.к. index переисп.) | Low | Conditional emission: только когда @category present. Test on validator |
| Article#author user не имеет agent_slug → Person @id reference broken | Low | Fallback на Organization @id (already designed in helper) |
| Site rebuild from photo_slider lazy-load fix → CLS regression | Low | После each fix run Lighthouse again на same page для regression check |

---

## Commit strategy

Один comprehensive commit для всех Schema/topology changes:
```
feat(seo): Tech/CTR bundle — CWV fixes + Article enrichment + HowTo + Hub pages
```

CWV audit document — отдельный commit (could be docs-only PR):
```
docs(seo): CWV audit 2026-05-19 — Lighthouse scores + ranked fixes
```

Total: 2 commits, ~10 файлов.

---

## DoD

- [ ] CWV audit doc создан в `.claude/docs/seo/`
- [ ] Top-3 CWV issues пофикшены AND verified через re-run Lighthouse
- [ ] Article#word_count, #reading_time_minutes, #iso_duration, #keywords_for_seo работают
- [ ] `_jsonld_article.html.erb` emits wordCount + timeRequired + articleSection + keywords + author
- [ ] `Seo::HowToExtractor` exists и extractable? returns true для article id=2 (guide)
- [ ] `_jsonld_how_to.html.erb` rendered on /blog/<guides-slug> с >= 3 steps
- [ ] `/blog/category/guides` renders dedicated view с H1 + intro + ItemList JSON-LD
- [ ] `/blog` index имеет category nav-bar
- [ ] `/sitemap-pages.xml` имеет 5 category URLs (когда есть articles)
- [ ] Smoke 10 URLs → 200/302
- [ ] validator.schema.org clean на всех modified pages
- [ ] Y.Webmaster recrawl submitted для new URLs

---

## Next step

После твоего review этого spec'a → invoke `superpowers:writing-plans` skill для создания implementation plan по этому design.
