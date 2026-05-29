# Lighthouse Baseline — 28.05.26

> Mobile-first аудит 5 ключевых страниц для Phase A polish design sprint. **Виewport**: 412×823 @ 1.75x (Pixel-like). **Backend**: lighthouse-13.3.0 + chromium-148 headless. **Cache**: clean run (no warmup).

## TL;DR

🚨 **Home + Property Show в красной зоне** (perf 43 / 50). Landings + cases — зелёные (91-99).

| Page | Perf | A11y | BP | SEO | LCP | TBT | Total | Stance |
|---|---|---|---|---|---|---|---|---|
| **Home** | **43** ⛔ | 91 | 100 | 100 | **12.4s** ⛔ | **1600ms** ⛔ | 2.9 MB | Critical |
| **Property show** | **50** ⛔ | 90 | 100 | 100 | 4.9s ⚠️ | 770ms ⚠️ | **6.8 MB** ⛔ | Critical |
| Premium landing | 91 ✅ | 94 | 100 | 66 ⚠️* | 1.7s ✅ | 70ms ✅ | 343 KB | OK + SEO P0 |
| District landing (kanishchevo) | 99 ✅ | 96 | 100 | 66 ⚠️* | 1.7s ✅ | 60ms ✅ | 349 KB | OK + SEO P0 |
| /cases | 98 ✅ | 94 | 100 | 100 | 2.1s ✅ | 40ms ✅ | 426 KB | Excellent |

\* SEO 66 = `<meta name="robots" content="noindex,follow">` — **бизнес-finding ниже**.

## P0 SEO finding (не дизайн, но обнаружено при аудите)

**Premium и district landings noindex'ятся когда @total_count == 0** (`app/views/landings/show.html.erb:73-75` — soft-404 guard). Это by-design. Но:

- `/kupit/kvartira/premium` defaults to `city='Рязань'` → но все 4 premium-квартиры в каталоге находятся **в Москве/СПб/Красногорске** (`2-komn-kvartira-64-5-m2-sankt-peterburg` 21.6M, etc) → @total_count=0 → noindex
- `/kupit/kvartira/rayon/kanishchevo` — 0 квартир в Канищево в каталоге → noindex

**Yandex Webmaster при этом показывает kanishchevo на pos 11** — historical ranking ДО noindex добавления, ИЛИ Yandex ranks разные URLs. Сейчас pages **не индексируются**.

**Развилка** (бизнес-решение, не код):
- **(A)** Получить premium-листинги в Рязани (контент) — Phase A priority
- **(B)** Снять city-filter с premium landing (catalog-wide premium) → 4 listings показываются + indexable
- **(C)** Создать city-specific premium URLs: `/moscow/kupit/kvartira/premium` etc — больше landings, indexable

Hand-off → `seo-content-curator` для решения. Это блокирует organic growth Phase A.

---

## Detailed findings per page

### 1. Home (`/`) — perf 43 ⛔

**Critical CWV**:
- **LCP 12.4s** (s=0): самая большая видимая картинка появляется через 12 секунд. Target < 2.5s.
- **TBT 1,600ms** (s=12): main thread заблокирован 1.6 сек. Target < 200ms.
- **Main thread breakdown 5.1s**: Style/Layout 2.3s, Script Eval 1.7s, Other 0.8s.

**Top payloads** (все ActiveStorage images, eager-loaded):
| Size | What |
|---|---|
| 551 KB | ActiveStorage image |
| 472 KB | ActiveStorage image |
| 417 KB | ActiveStorage image |
| 341 KB | ActiveStorage image |
| 253 KB | ActiveStorage image |
| 127 KB | HTML response |

→ **~2 MB только в hero/featured image carousels** на одной странице. Caches `max-age=900` но это first-paint.

**Other issues**:
- `color-contrast` (a11y 0%): где-то текст с insufficient contrast — нужен audit DevTools.
- `unused-javascript` 46 KB
- `unminified-javascript` 2 KB

**Likely culprits** (требует view inspection):
- `home/index.html.erb` 598 LOC рендерит featured properties + recent articles → каждая загружается с hero variant
- No `<picture>` markup — JPEG only (WebP variant defined но не используется в helper)
- Лазовое decoding активно но количество огромно

**Improvement levers** (Phase 2+3):
1. **AVIF + WebP variants** на Article (cover_image) — экономия 30-50%
2. **Lazy below-the-fold** — featured carousel ниже fold должен loaded после LCP
3. **Fragment cache** на featured/news partials — `expires_in 15.minutes` уже на controller, но partials повторно renderятся
4. **Decompose home/index.html.erb** → easier to profile bottlenecks

### 2. Property show (`/properties/[premium-slug]`) — perf 50 ⛔

**Critical CWV**:
- **LCP 4.9s** (s=29)
- **TBT 770ms** (s=38)
- **Total 6.8 MB** ⛔ — самая тяжёлая страница

**Top payloads**:
| Size | What |
|---|---|
| **689 KB** | **Yandex Maps JS (front-maps-static v2.1.79)** |
| 378 KB | HTML response (large property show — 647 LOC view) |
| 223 KB × 7 | Gallery images (ActiveStorage) |
| 90 KB | Yandex Metrika tag |

**Unused JavaScript**:
- Yandex Maps: **481 KB unused (70%)** — eager loaded, но карта обычно ниже первого экрана
- Yandex Metrika: 44 KB unused (49%)

**Other issues**:
- `heading-order` (a11y 0%): нарушение order H1→H2→H3
- `link-name` (a11y 0%): какие-то ссылки без discernible name (icon-only buttons?)
- `color-contrast` (a11y 0%)

**Improvement levers** (Phase 2+3):
1. **Defer Yandex Maps until intersection** — `IntersectionObserver` загружает JS только когда user scroll'нул до map. **Огромный win** (~480 KB JS отложено).
2. **Gallery lazy beyond first 2-3 images** — slider preload только active + adjacent.
3. **AVIF + WebP в gallery** — 50% saving на 7 images = ~700 KB.
4. **Decompose properties/show.html.erb** → extract `_gallery`, `_specs`, `_location`, `_similar` partials с fragment cache.
5. **A11y fixes**: heading-order audit, link-name на iconic buttons.

### 3. Premium landing — perf 91 ✅, SEO 66 ⚠️

**SEO 66** — fully attributable to `noindex` (см. P0 finding выше). Если решим открыть для индексации, SEO score прыгнет на 100.

**Minor CLS 0.171** (s=70): layout shift во время load. Скорее всего late-loaded image или font swap.

**Otherwise solid** — этот landing template работает хорошо когда контент есть.

### 4. District landing (`/kupit/kvartira/rayon/kanishchevo`) — perf 99 ✅, SEO 66 ⚠️

Лучший perf score в наборе. SEO 66 = noindex (см. P0).

### 5. /cases — perf 98 ✅

Excellent. Лучший пример того, как нужно строить страницы.

---

## Action priorities (для Phase 2+3 design sprint)

### Quick wins (≤1 day total)

| # | Action | Page | Est impact | Phase |
|---|---|---|---|---|
| Q1 | **Defer Yandex Maps load** (intersection observer) | property show | LCP -2s, total -480 KB | 3 |
| Q2 | **Lazy gallery beyond first 3 images** | property show | LCP -1s, total -1 MB | 3 |
| Q3 | **AVIF variants для Article/CaseStudy/Property** | home + show | 30-50% image savings | 2 |
| Q4 | **`<picture>` markup в `image_with_lazy` helper** | все | enables Q3 | 2 |

### Medium effort (Phase 3 decomposition)

| # | Action | Page | Est impact | Phase |
|---|---|---|---|---|
| M1 | **Decompose home/index.html.erb** (6 partials + fragment cache) | home | LCP -3-5s, TBT -800ms | 3 |
| M2 | **Decompose property show** (6 partials + fragment cache) | property show | LCP -1.5s, TBT -300ms | 3 |
| M3 | **A11y fixes**: heading-order, link-name, color-contrast | property show, home | a11y 90→97+ | 3 (часть) |

### SEO P0 (вне sprint, бизнес-решение)

| # | Action | Page | Est impact | Owner |
|---|---|---|---|---|
| SEO1 | **Решить premium landing strategy** (см. развилку A/B/C) | premium | unblock organic growth | seo-content-curator |
| SEO2 | **Audit district landings × catalog** — какие districts pустые и noindex (не только kanishchevo) | landings/* | бизнес-видимость | seo-content-curator + mkt-analytics |

### Deferred (low ROI этого sprint)

- Unminified JS 2 KB — rounding error, asset pipeline уже минифицирует, скорее всего inline `<script>` где-то
- Color-contrast — нужен per-element audit; делать после design system formalisation (Phase 4)

---

## Files (raw lighthouse JSONs)

```
docs/design-improvements/lighthouse/
  home-mobile.json              507 KB
  property-show-mobile.json     ~500 KB
  premium-landing-mobile.json   ~400 KB
  district-landing-mobile.json  ~400 KB
  cases-mobile.json             ~400 KB
```

Re-run: `npx lighthouse https://victory62.org/<path> --chrome-flags="--headless=new --no-sandbox" --form-factor=mobile --output=json --output-path=docs/design-improvements/lighthouse/<name>.json --quiet --chrome-path=/usr/bin/chromium`.

## Desktop audits (not yet run)

Mobile prioritized due to Yandex mobile-first ranking. Desktop run после Phase 3 для regression-comparison (+ Yandex Webmaster показывает что 70%+ traffic mobile).

## Hand-offs

- **Phase 2 (image pipeline)** — Q3/Q4 confirmed как known wins
- **Phase 3 (view decomposition)** — приоритеты Q1/Q2 + M1/M2 (home первый, потом property show)
- **`seo-content-curator`** — SEO1/SEO2 outside sprint
- **`yandex-webmaster-seo-ops`** — re-check ИКС + opportunities через 4 недели после Phase 3 ship'a; expected SQI +5-10 pts от LCP improvements
