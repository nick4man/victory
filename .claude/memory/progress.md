# progress.md — что в проде, что выключено, что заглушка

> Что реально работает на https://victory62.org на момент написания. Обновляй по факту прод-релизов.

## Status: PRODUCTION — live at https://victory62.org

## Активно в проде

| Подсистема | Статус | Примечания |
|-----------|--------|-----------|
| Landing | ✅ active | `landing#index` корневой роут, full app layout с header/footer, news strip над featured properties |
| Properties (каталог) | ✅ active | TopNLab MLS-синхронизация, поиск/карта/сравнение |
| Investment Audit | ✅ active | audit-engine sidecar анализатор |
| Express valuation | ✅ active | гедонический + bootstrap CI; есть PDF + TG-нотификации |
| Mortgage Calculator | ✅ active | 22 банковские программы |
| News section | ✅ active | webhook-ingest из chat-host; embeddings; swipe-carousel; modal-preview; share/TG CTA |
| Reviews | ✅ active | admin-modеration |
| Chat-bot | ✅ active | с tools (см. `app/services/chat_tools/`) |
| Admin panels | ✅ active (token-guarded) | `Admin::Reviews`, `Admin::Articles` — `?token=$ADMIN_TOKEN` |
| Telegram inbox | ✅ active | приём входящих в site, async photo download |
| TG ↔ victory62 cross-link | ✅ Phase 8 deployed | bilateral notifications, QR codes на обоих отчётах |

## Отключено / заглушки

| Подсистема | Состояние | Когда вернётся |
|-----------|----------|----------------|
| **Devise** (user login) | отключен | future iteration; до этого admin через `?token=$ADMIN_TOKEN` |
| `current_user` | заглушка — всегда `nil` | вместе с Devise |
| `user_signed_in?` | заглушка — всегда `false` | вместе с Devise |
| **Sidekiq workers** | в Gemfile есть, частично активирован | для high-load очередей |
| **Pundit** policies | gem может быть, но политик нет; guards `require_admin!` / `require_agent!` живут в ApplicationController как stubs | при возврате Devise |

## Аспирационные роуты (без контроллеров)

`config/routes.rb` упоминает контроллеры, которые могут отсутствовать в реальности:
`BlogController`, `NewsController` (частично), `SitemapController`, `RobotsController`, `PwaController`, `HealthController`, `ErrorsController`, `ChatController`, `ChatbotController`, `SellController`, `ServicesController`, `FormsController`, `WebhooksController`.

> Проверяй наличие через `ls app/controllers/` перед предположением, что endpoint работает.

## Landing — особенность

`app/views/landing/index.html.erb` исторически был **self-contained** HTML (Tailwind с CDN, без application layout). Сейчас перешли на full app layout (см. activeContext). Если правишь — проверь, что не сломал layout-обёртку.

## Локаль

Всё пользовательское — на **русском**. Поддержка `en` номинальная.

## Известные продовые гарантии

- Ransack-параметры контролируются явным allowlist на `Property` (`ransackable_attributes` и т.д.) — не открывать произвольные поля.
- Soft delete: `User` и `Property` оба используют `deleted_at` + `default_scope { not_deleted }`. Доступ к удалённым — `.unscoped`.
- PostGIS-запросы — raw SQL через `earth_distance` / `ll_to_earth`; не переходим на postgis-AR-адаптер.

## Известные проблемы / tech debt

- **Тесты**: 5 spec файлов на 328 модулей. Покрытие минимальное — рефакторинг крупных файлов рискованный.
- **Линтинг**: `.rubocop.yml` есть, но rubocop/brakeman/bundler-audit отсутствуют в Gemfile. Phase 4 — добавить.
- **Hot-spots по LOC**: `Property` модель ~710, `DashboardController` ~624, `PropertiesController` ~584. Кандидаты на декомпозицию (Phase 2 — rails-architect агент).
- **Hedonic valuation overshoot**: ранее наблюдалось завышение (Дубровичи 25.2М ₽ вместо 7М). `property-valuation-expert` агент компенсирует через CMA-аналоги.
