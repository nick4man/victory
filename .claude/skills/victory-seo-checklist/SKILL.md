---
name: victory-seo-checklist
description: Use when creating or modifying a public-facing page on victory62.org (view, route, controller, landing, article). Walks through the SEO checklist (meta, JSON-LD, OG, canonical, breadcrumb, alt-tags, robots, Yandex specifics) so the page ranks well in both Google and Yandex.
---

# Victory62 SEO Checklist

Применяй на любой public-facing странице. Russian real estate, RU-market = **Yandex + Google equally**.

## Required (без этого не публикуй)

### 1. `<title>` уникальный, ≤60 символов

```erb
<% content_for :title, "Купить 2-комн квартиру в Дубровичах — АН Виктори" %>
```

- Ключевое слово в **начале**
- Город/район — для local SEO
- «АН Виктори» — в конце (brand)
- НЕ дубль для разных страниц

### 2. `<meta name="description">` ≤160 символов, CTA

```erb
<% content_for :seo_description, "2-комнатная квартира в Дубровичах, 54 м², 3 этаж, ремонт. Цена 4 500 000 ₽. Просмотры по записи. Звоните!" %>
```

- Содержит ключевые слова естественно
- Заканчивается CTA («Звоните», «Узнайте подробности»)
- Не дублирует title

### 3. `<h1>` один на страницу, синхронизирован с title

```erb
<h1 class="text-3xl font-bold">2-комн квартира в Дубровичах</h1>
```

### 4. Canonical URL без query-string

В `app/views/layouts/application.html.erb` уже есть helper `canonical_url`. Проверь:

```erb
<link rel="canonical" href="<%= canonical_url %>">
```

### 5. OG tags

```erb
<% content_for :og_type, 'product' %>  <!-- или 'website' / 'article' -->
<% content_for :og_image, og_image_url(@property) %>
<% content_for :og_image_width, 1200 %>
<% content_for :og_image_height, 630 %>
```

OG image: 1200×630, реальная картинка (не placeholder)

### 6. JSON-LD по типу страницы

| Page type | JSON-LD @type | Partial |
|---|---|---|
| Главная | `WebSite` + `SearchAction` | `shared/_jsonld_website_search` (TODO — Phase 2B) |
| Property show | `RealEstateListing` / `Apartment` / `House` + `offers` | `shared/_jsonld_property` |
| Article show | `Article` / `NewsArticle` | `shared/_jsonld_article` |
| Landing с FAQ | `FAQPage` | `shared/_jsonld_faq` |
| Contacts | `LocalBusiness` | `shared/_jsonld_localbusiness` |
| Any non-root | `BreadcrumbList` | `shared/_jsonld_breadcrumb` |

И **глобально на каждой странице** — `RealEstateAgent` (из `shared/_jsonld_agent`).

### 7. Breadcrumb (UI + JSON-LD)

```erb
<%= render 'shared/breadcrumb', items: [
  { name: 'Главная', url: root_path },
  { name: 'Купить', url: properties_path(deal_type: 'sale') },
  { name: @property.district, url: properties_path(district: @property.district) },
  { name: @property.title, url: property_path(@property) }
] %>
```

JSON-LD генерится автоматом через `breadcrumb_jsonld` helper.

### 8. Images: alt + lazy + responsive

```erb
<!-- hero (above fold) -->
<%= image_tag property.images.first,
              alt: property_image_alt(property),
              loading: 'eager', decoding: 'async' %>

<!-- below fold -->
<% property.images[1..].each do |img| %>
  <%= image_tag img, alt: property_image_alt(property),
                loading: 'lazy', decoding: 'async' %>
<% end %>
```

- `property_image_alt` уже есть; генерит «Купить 2-комн, 65 м² в Советском, Рязань»
- Responsive: используй Active Storage variants (`thumb`/`card`/`hero`)

### 9. Robots

| Page | meta |
|---|---|
| Public listing | (default — без меты, allow indexing) |
| `/dashboard/*` | `<meta name="robots" content="noindex, nofollow">` |
| Search results (queries) | `<meta name="robots" content="noindex, follow">` |
| Print/AMP версии | canonical к base URL |

Глобально в `robots.txt` (через `RobotsController`) — `/dashboard/*` уже disallowed.

### 10. Yandex-специфичное

```erb
<!-- В <head> -->
<% if ENV['YANDEX_VERIFICATION'].present? %>
  <meta name="yandex-verification" content="<%= ENV['YANDEX_VERIFICATION'] %>">
<% end %>

<!-- Geo (для Яндекс ранжирования по региону) -->
<meta name="geo.region" content="RU-RYA">
<meta name="geo.placename" content="Ryazan">
<meta name="geo.position" content="<%= property.latitude %>;<%= property.longitude %>" if @property&.coordinates?>
```

## Optional (улучшения)

- **hreflang**: `<link rel="alternate" hreflang="ru" href="..."> + <link rel="alternate" hreflang="x-default" href="...">`
- **Schema.org `Place`** или **`Residence`** для landings районов
- **AMP-страницы** для articles (если оптимизация на mobile-speed критична)
- **OG video** если есть video tour

## Validation checklist (после коммита)

```
□ Google Rich Results Test: https://search.google.com/test/rich-results
□ Schema.org validator:    https://validator.schema.org
□ OG tester:               https://opengraph.dev/
□ Yandex.Webmaster:        Tools → Microformat checker (если у вас доступ)
□ Lighthouse SEO score:    через chrome-devtools-mcp lighthouse_audit (≥85)
□ Page Speed Insights:     LCP < 2.5s, CLS < 0.1
```

## Anti-patterns

- ❌ Один title на похожие страницы (`Купить квартиру` на 100 листингах)
- ❌ JSON-LD с полями, которых нет в видимом контенте — Google флагает spam
- ❌ Canonical с query string (`?q[district]=...`) — strip params
- ❌ Все картинки `loading="lazy"` — hero должен быть eager
- ❌ Дубль `og:image` без width/height — VK/Facebook ругаются
- ❌ Скрытый текст для ботов — Google наказывает
- ❌ Множество H1 — один на страницу

## Connected agent

Если вопрос конкретный или нужна реализация — запусти **`seo-content-curator`** агента, он знает codebase карту и реализует по этому чек-листу.

## Reference

- Audit состояния: см. отчёт в `splendid-imagining-lerdorf.md` Phase 2 plan section
- Полные конвенции: `.claude/memory/systemPatterns.md`
- Что в проде: `.claude/memory/progress.md`
