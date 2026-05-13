# Google Analytics 4 (GA4) — setup guide

> На момент написания партнал `app/views/shared/_analytics.html.erb` уже имеет GA4 блок dormant: он fires только когда `ENV['GOOGLE_ANALYTICS_ID']` установлен в production. Этот гайд — как получить ID и активировать.

## Контекст: что такое GA4

- **Google Analytics 4** — текущая (с июля 2023) версия аналитики Google
- Заменила Universal Analytics (UA) — старые `UA-XXXXX-Y` ID **больше не работают**
- GA4 использует event-based модель (всё событие, не page view)
- Measurement ID формат: `G-XXXXXXXXXX` (10 alphanumeric chars после `G-`)

## Шаг 1: Зарегистрировать GA4 свойство

⚠️ **Если `analytics.google.com` недоступен из РФ** — нужен VPN/прокси для UI. Сами скрипты `googletagmanager.com` доступны из РФ напрямую (CDN другой).

### Через VPN/прокси

1. https://analytics.google.com → войти в Google аккаунт
2. Admin (шестерёнка слева внизу)
3. **Create property** → ввести:
   - Property name: `victory62.org`
   - Reporting time zone: `Europe/Moscow`
   - Currency: `RUB`
4. Business details:
   - Industry: Real estate
   - Business size: Small (если до 10 employees)
5. Business objectives — выберите:
   - Generate leads
   - Examine user behavior
6. Choose platform: **Web**
7. Set up data stream:
   - Website URL: `https://victory62.org`
   - Stream name: `Victory62 production`
   - Enhanced measurement: оставить включённым (scroll, outbound clicks, site search, video, file downloads)
8. **Measurement ID** появится — формат `G-XXXXXXXXXX`. Скопировать.

### Через мобильное Google Analytics приложение

Если desktop UI недоступен — приложение `Google Analytics` (iOS/Android) работает напрямую через Google CDN, обычно проходит без VPN. Можно создать property оттуда.

## Шаг 2: Положить ID в production `.env`

```bash
# .env (production)
GOOGLE_ANALYTICS_ID=G-XXXXXXXXXX
```

`.env.example` уже содержит placeholder.

## Шаг 3: Verify в Real-Time

1. Deploy на prod
2. Открыть `https://victory62.org` в incognito (свежая сессия)
3. GA Admin → Reports → Realtime
4. Должны увидеть `1 user in last 30 minutes`
5. Кликнуть по странице — увидеть event в Real-Time stream

## Шаг 4: Базовые настройки

### Enhanced measurement (recommended)

В GA Admin → Data Streams → Web stream → Enhanced measurement:
- ✅ Page views
- ✅ Scrolls
- ✅ Outbound clicks
- ✅ Site search
- ✅ Form interactions
- ✅ Video engagement
- ❌ File downloads (для риелтора обычно не нужно)

### Custom events для real-estate (recommended)

Можно отслеживать специфичные действия:

```javascript
// клик «Связаться» на property
gtag('event', 'lead_contact_click', {
  property_id: '<%= property.id %>',
  property_type: '<%= property.deal_type %>',
  district: '<%= property.district %>',
  price: <%= property.price %>
});
```

Реализация — отдельная задача (новый Stimulus controller `analytics-events`).

### Conversions

В GA Admin → Events → mark as conversion:
- `lead_contact_click`
- `mortgage_calculate_submit`
- `valuation_submit`
- (любое custom event как конверсия)

## Альтернативы — pro-privacy / self-hosted

Если GA4 не подходит (GDPR/152-ФЗ опасения, VPN issues, performance):

| Alt | Pros | Cons | Cost |
|---|---|---|---|
| **Plausible** | Self-hostable, GDPR-friendly, no cookies, ~1 KB script | Платный hosted ($9/mo); self-host = свой сервер | Free (self-host) / $9+/mo |
| **Umami** | Open-source, self-hostable, similar к Plausible | Self-host обязателен для бесплатного | Free (self-host) |
| **Counter.dev** | Privacy-first, minimal, free | Меньше функций | Free |
| **GoatCounter** | Open-source, very minimal | Не event-based | Free / $5/mo hosted |

Если хотите Plausible/Umami — отдельная задача. Партиал `_analytics.html.erb` можно расширить ещё одним if-guarded блоком с `PLAUSIBLE_DOMAIN` ENV.

## Yandex.Metrika + GA4 одновременно

Это нормальная практика — RU-аудитория попадёт в обе системы. У Yandex.Metrika лучше Russian context (мобильные провайдеры, регионы РФ). У GA4 — глобальная картина, integration с Google Search Console и Google Ads.

## Verification после deploy

```bash
# 1. ENV установлен
echo $GOOGLE_ANALYTICS_ID

# 2. Скрипт грузится
curl -sL https://victory62.org/ | grep "googletagmanager.com/gtag/js"

# 3. Real-Time показывает посещения
# (открыть GA dashboard → Realtime)

# 4. Browser DevTools → Network → отфильтровать gtag — должны быть requests
```

## Troubleshooting

| Симптом | Причина | Решение |
|---|---|---|
| Не появляется в Real-Time | ENV не подхватился | `sudo systemctl restart victory-web` |
| 0 events 24 ч | adblock / DNT | проверьте без adblock в incognito |
| `gtag is not defined` | partial не renderится | проверьте `Rails.env.production?` |
| Скрипт грузится но events 0 | Browser CSP | проверьте Content-Security-Policy header |

## Связанные доки

- `search-console-setup.md` — Search Console (поисковые запросы → сайт)
- `indexnow-setup.md` — push индексация Bing/Yandex/Brave
- `app/views/shared/_analytics.html.erb` — реализация
- `.claude/skills/victory-seo-checklist/SKILL.md` — общий чек-лист
