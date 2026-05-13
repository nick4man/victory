# Google Search Console — setup guide

> Search Console — это сервис Google для **владельцев сайтов**, показывает: какие запросы привели юзеров, какие страницы индексируются, error reports, Core Web Vitals, mobile usability. Это **другой** сервис, не Google Analytics 4 (GA4) — но они часто используются вместе.

## TL;DR

1. Зарегистрировать домен в Search Console
2. Verify ownership одним из 5 методов
3. Submit `sitemap.xml`
4. Через 24-48 ч начнут появляться запросы

Самый простой verification — meta-tag (`<meta name="google-site-verification" content="...">`). Уже есть инфраструктура в проекте через ENV `GOOGLE_SITE_VERIFICATION`.

## Шаг 1: Открыть Search Console

URL: https://search.google.com/search-console

Если из РФ недоступен — нужен VPN/proxy для UI. **Сам verification meta-tag работает напрямую** (Google crawler проверяет от своего датацентра).

## Шаг 2: Добавить property

Есть два типа property:

### Domain property (recommended)

Покрывает все поддомены и протоколы:
- `victory62.org`, `www.victory62.org`, `https://`, `http://` — всё одной property

**Verification**: только DNS TXT-record. У вас должен быть доступ к DNS-провайдеру (Cloudflare, Beget, REG.RU, любой).

Шаги:
1. Add property → Domain → ввести `victory62.org` (без https://, без www)
2. Google показывает TXT record типа `google-site-verification=<token>`
3. Добавить в DNS: `@` TXT `google-site-verification=...` (TTL=300)
4. Подождать 5-30 min, нажать Verify

### URL prefix property

Покрывает только один префикс — `https://victory62.org/` отдельно от `http://`, `www.`, etc.

**Verification**: 5 методов на выбор.

#### Метод 1: HTML meta tag (самый простой)

1. Add property → URL prefix → `https://victory62.org/`
2. Google даст meta tag типа `<meta name="google-site-verification" content="abcDEF123..." />`
3. Извлечь content (всё что в `content="..."`)
4. Положить в `.env`:
   ```bash
   GOOGLE_SITE_VERIFICATION=abcDEF123_long_random_string
   ```
5. В victory62 layout (вероятно уже есть) подхват через ENV:
   ```erb
   <% if ENV['GOOGLE_SITE_VERIFICATION'].present? %>
     <meta name="google-site-verification" content="<%= ENV['GOOGLE_SITE_VERIFICATION'] %>">
   <% end %>
   ```
6. Deploy → нажать Verify в Search Console

#### Метод 2: HTML file upload

Загрузить файл вида `google<hash>.html` в `public/` корне сайта. У вас уже есть один — `public/google9b7f1e84e9aa72f5.html`. Это значит **вы уже verified** через этот метод! Property = `victory62.org` URL-prefix.

#### Другие методы

- DNS TXT (только для Domain property)
- Google Analytics — линк с GA4 (если есть)
- Google Tag Manager — если используете GTM

## Шаг 3: Проверить текущий стейт verification

В victory-сессии:

```bash
bin/rails runner 'puts ENV["GOOGLE_SITE_VERIFICATION"].inspect'
# nil — meta-tag method не использован
# "abc..." — meta-tag установлен
```

И проверка file-upload:
```bash
ls public/google*.html
# google9b7f1e84e9aa72f5.html — есть, значит verified этим методом
```

## Шаг 4: Submit sitemap

После verification:

1. Search Console → Sitemaps (левое меню)
2. Add a new sitemap: `https://victory62.org/sitemap.xml`
3. Click Submit
4. Status `Success` — Google начнёт crawl'ить URLs из sitemap

У victory62 есть **два** sitemap'а:
- `/sitemap.xml` — общий (Properties + Articles + Agents + Landings)
- `/sitemap-news.xml` — news ≤48ч для Google News

Submit оба отдельно.

## Шаг 5: Полезные отчёты

### Performance (главный)

- **Queries** — какие поисковые запросы привели на сайт
- **Pages** — какие страницы получили клики
- **Countries** — география трафика
- **Devices** — mobile vs desktop
- **Search appearance** — был ли rich result показан

Фильтры:
- Date range — последние 28/90 дней
- Query contains «купить квартиру» — какой trafic на коммерческие запросы
- Page contains `/properties/` — performance отдельных listings

### Indexing → Pages

- Indexed pages — сколько в индексе
- Not indexed reasons:
  - Crawled — not indexed (нет ценности)
  - Discovered — not indexed (не дошли crawler'ом)
  - Excluded by noindex (correct, для `/dashboard/*`)
  - Soft 404 (страница пустая)

### Experience → Core Web Vitals

- **LCP** (Largest Contentful Paint) — должно < 2.5s
- **CLS** (Cumulative Layout Shift) — должно < 0.1
- **INP** (Interaction to Next Paint) — должно < 200ms

Если у property cards плохой LCP — добавить `priority: true` в первый `property_picture`.

### Enhancements → разделы (если найдены)

- **Breadcrumbs** — должны быть валидны (мы используем JSON-LD BreadcrumbList)
- **Logo** — Search Console показывает логотип в SERP (нужен `Organization` JSON-LD с `logo`)
- **Sitelinks searchbox** — должен появиться после **WebSite+SearchAction** JSON-LD (Item 1 в Phase 2B, см. `splendid-imagining-lerdorf.md`)

### URL Inspection

- Ввести URL → проверить как Google его видит
- See "Test live URL" — что crawler видит **прямо сейчас**
- "Request indexing" — manual push (не масштабируется, для дебага)

## Yandex.Webmaster — параллельно

Yandex имеет аналог. Уже есть file `public/yandex_73b43b00444a369b.html` → значит verified. Адрес: https://webmaster.yandex.com/sites/

Submit sitemap аналогично, в RU больше пользы от Yandex Webmaster чем Google Search Console.

## ENV vars

```bash
# .env (already supported by layout, just set value)
GOOGLE_SITE_VERIFICATION=        # если хотите meta-tag verification
YANDEX_VERIFICATION=             # если хотите meta-tag verification (вместо file)
```

Если verified через файл — переменные могут быть пустыми, всё равно работает.

## Anti-patterns

- ❌ Не submit'ить sitemap несколько раз — overhead на Google; submit один раз
- ❌ Не использовать «Request Indexing» батчем — это для дебага одной URL, не для сотен
- ❌ Не игнорировать «Soft 404» отчёты — это значит у вас есть пустые/тонкие страницы
- ❌ Не путать Search Console с Analytics — они показывают **разные данные** (запросы vs поведение)

## Связанные доки

- `ga4-setup.md` — Google Analytics 4 (поведение пользователей)
- `indexnow-setup.md` — push индексация для других engines (Google не поддерживает IndexNow)
- victory-seo-checklist skill
