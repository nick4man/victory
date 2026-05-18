---
name: yandex-webmaster-api-patterns
description: Use when interacting with Yandex.Webmaster API v4 for victory62.org SEO operations — pulling search-query stats (impressions/clicks/CTR/position), detecting optimisation opportunities (high-impressions+low-CTR+middle-position queries), requesting recrawl with quota discipline, reading diagnostics (active site issues), tracking SQI trend, or troubleshooting failing endpoints. Captures the verified endpoint catalogue (some paths differ from public docs — see API quirks section), opportunity detection thresholds, recrawl quota safety, privacy rules для search-query data, common errors → fix matrix. OAuth setup steps live в `.claude/docs/yandex-webmaster-oauth-setup.md`. RELATED (.claude/docs/delegation-map.md) — pair with agent `yandex-webmaster-seo-ops` для actual workflows (digest / opportunities / recrawl); coordinate с `seo-content-curator` for title/meta rewrites after opportunity detection; with `market-analytics-publisher` для surfacing top-query trends в weekly content.
---

# Yandex.Webmaster API v4 — patterns & quirks

Reference for working with `https://api.webmaster.yandex.net/v4/`. Verified endpoints + actual response shapes (live tested 18.05.2026 на victory62.org).

## Auth

OAuth token + user_id из env (см. `.claude/docs/yandex-webmaster-oauth-setup.md`):

```bash
TOKEN=$YANDEX_WEBMASTER_TOKEN
USER_ID=$YANDEX_WEBMASTER_USER_ID
HOST_ID='https:victory62.org:443'  # ← non-URL-encoded — colons as-is

curl -H "Authorization: OAuth $TOKEN" \
     "https://api.webmaster.yandex.net/v4/user/$USER_ID/hosts/$HOST_ID/<path>"
```

Token не expires (вечный) пока не отозван в passport.yandex.ru.

## Verified endpoints (working, with response shape)

| Path | Status | Returns |
|---|---|---|
| `/user/` | 200 | `{user_id}` |
| `/user/<uid>/hosts/` | 200 | `{hosts: [{host_id, ascii_host_url, verified, ...}]}` |
| `/user/<uid>/hosts/<h>/summary/` | 200 | `{sqi, searchable_pages_count, excluded_pages_count, sitemap_count, ...}` |
| `/user/<uid>/hosts/<h>/sqi-history/` | 200 | `{points: [{date, value}, ...]}` |
| `/user/<uid>/hosts/<h>/sitemaps/` | 200 | `{sitemaps: [{sitemap_url, last_access_date, errors_count, urls_count}]}` |
| `/user/<uid>/hosts/<h>/search-queries/popular/` | 200 | `{queries: [{query_text, indicators: {TOTAL_SHOWS, TOTAL_CLICKS, AVG_SHOW_POSITION, AVG_CLICK_POSITION}}]}` |
| `/user/<uid>/hosts/<h>/diagnostics/` | 200 | `{problems: {KEY: {severity, state, last_state_update}}}` — **HASH, not array** |
| `/user/<uid>/hosts/<h>/recrawl/queue/` | 200 | `{count, tasks: [{task_id, url, added_time, state}]}` — list существующих |
| `/user/<uid>/hosts/<h>/recrawl/quota/` | 200 | `{daily_quota, quota_remainder}` — **NOT `/recrawl/queue/quota/`** |

## NOT-working paths (verified 404 / wrong)

| Tried | Result | Why |
|---|---|---|
| `/recrawl/queue/quota/` | 400 (parses `quota` as task-id UUID) | Use `/recrawl/quota/` instead |
| `/popular-pages/` | 404 RESOURCE_NOT_FOUND | Likely moved or never existed at this path |
| `/indexing-history/` | 404 | Same |
| `/external-links-history/` | 404 | Same |

If user requests these — try alternative endpoints (search-queries history, sitemap urls, etc.) or report not available.

## API quirks (critical)

### Quirk 1 — FlatParamsEncoder для multi-value params

Yandex expects `query_indicator=A&query_indicator=B`, NOT `query_indicator[]=A&query_indicator[]=B`.

Faraday default — bracketed. Override:

```ruby
Faraday.new(
  BASE_URL,
  request: { params_encoder: Faraday::FlatParamsEncoder, ... }
)
```

### Quirk 2 — host_id format

`host_id` НЕ URL-encoded в path. Format: `https:domain:port`:

```
https:victory62.org:443     # production HTTPS
http:dev.example.com:80     # dev HTTP
```

GET `/user/<uid>/hosts/` returns `host_id` готовый к подстановке.

### Quirk 3 — Diagnostics shape

`/diagnostics/` returns:

```json
{
  "problems": {
    "FAVICON_PROBLEM": {
      "severity": "RECOMMENDATION",
      "state": "PRESENT",
      "last_state_update": "2026-05-17T20:23:35.745+03:00"
    },
    "SOFT_404": {
      "severity": "POSSIBLE_PROBLEM",
      "state": "ABSENT"
    }
  }
}
```

`state: PRESENT` = активная проблема. `state: ABSENT` = всё чисто. Filter when normalising — total `keys = 34` (full diagnostic checklist), `active = problems.select { |_, v| v['state'] == 'PRESENT' }`.

Severity scale: `FATAL > ERROR > POSSIBLE_PROBLEM > RECOMMENDATION`.

### Quirk 4 — Recrawl quota path

**`/recrawl/quota/`** (без `queue/`). Sibling, не дитя.

Tried `/recrawl/queue/quota/` → 400 Yandex parses `quota` как task-id (UUID format expected). One of the few non-RESTful path choices.

Default daily quota for verified host: **150** (was 5-10 in older docs — verified live 18.05.2026).

## Opportunity detection — thresholds & rationale

`Yandex::WebmasterOpportunitiesService` defaults:

| Param | Default | Why |
|---|---|---|
| min_impressions | 50 | Real demand signal — single-digit noise/long-tail |
| max_ctr | 3% (0.03) | TOP-10 avg CTR 5-15%; below 3% — weak snippet/title |
| position_range | 4..15 | pos > 20 too obscure; pos < 4 already TOP, CTR-game over; 4-15 — already ranking, fixable |

### Target CTR by position (rough Yandex aggregates)

```
pos 1     ~24%   (#1 — все клики идут)
pos 2     ~16%
pos 3     ~11%
pos 4-5   ~6-8%
pos 6-10  ~3-5%
pos 11-20 ~1-2%
```

Service вычисляет `missed_clicks_estimate = (target_ctr - current_ctr) * impressions` — оценка сколько кликов недополучаем при weak snippet, при условии что CTR можно поднять до target.

### Output ranked by missed_clicks (DESC)

Highest potential first → optimise top of list = max impact.

## Recrawl quota discipline

Daily: **150** recrawls (verified). Strategy:

| Trigger | Recrawl? | Reason |
|---|---|---|
| New programmatic landing publish | YES, single URL | Fast indexation |
| Title/meta rewrite on existing page | YES, single URL | Push new snippet |
| Property listing update (price change) | NO (auto через sitemap lastmod) | Don't burn quota on routine updates |
| Mass content cleanup (10+ pages) | Batch с rate-limit; verify quota >= count | Don't drain |
| sitemap.xml regenerate | NO directly; recrawl `/sitemap.xml` URL вместо | sitemap pull triggers indexing |

`WebmasterRecrawlService.queue(url)` enforces:
- `min_remaining` (default 1) — refuse if quota left < this
- `burn_threshold` (default 0.8) — refuse if used > 80% of daily

Override via params for bulk recrawl (with user explicit OK).

## Privacy — search-query data

**Critical:** search-queries содержит actual user input в Yandex. Edge cases:
- Адреса конкретных квартир («купить 3-комн ул. Сенная 18-21») — leaks property info
- Имена клиентов («Лена Максик квартира») — leaks client names
- Phone numbers, emails если кто-то их вводил

Agent rules:
1. **Aggregate metrics OK** — counts, percentages, top-N
2. **Raw query text** — only показывать **в текущей session context** для work; **MUST NOT log в shared logs / inbox messages**
3. **При hand-off** к другим agents — strip raw query text, передавать aggregates only
4. **PII detection** — если в query видим адрес/имя/телефон, помечать «PII detected — query masked» в outputs

## Common errors → fixes

| Error | Cause | Fix |
|---|---|---|
| HTTP 401 | OAuth token expired / revoked | Re-do OAuth flow (см. setup doc) |
| HTTP 403 | Permissions missing in OAuth app | Re-create app с правами `webmaster:hosts:info,verify,write` |
| HTTP 404 на путях | Endpoint неверный | Compare с verified table выше |
| HTTP 400 task-id UUID | Path treats sub-segment как UUID | Likely missing `?param=` — Yandex parses as ID |
| HTTP 429 | Rate-limit | Retry с backoff (Faraday уже retries) |
| Empty response sections | Site новый / Yandex ещё не накопил data | Wait — некоторые метрики populate через 7-30 дней after верификация |

## Cache policy

`WebmasterSummaryService` — **12h cache** в Rails.cache (всё `fetch` под одним key). Force refresh:

```ruby
Yandex::WebmasterSummaryService.call(force_refresh: true)
# или:
Yandex::WebmasterSummaryService.bust!
```

Когда force_refresh:
- After publish (через 24-48h дать Yandex накопить data, then refresh)
- After recrawl trigger (verify task entered queue)
- On user request «свежие данные»

When NOT:
- В KPI hook (12h fresh enough)
- В weekly digest (Monday cron uses 12h cache OR force при wider freshness need)

## When to hand off

- **Opportunity → optimisation work** → agent `seo-content-curator` rewrites title/meta для top opportunities
- **Macro market analysis based on queries** → agent `market-analytics-publisher` (e.g., trending queries → content topics)
- **Recrawl after Property/Article publish** → `yandex-webmaster-seo-ops` (this agent) wraps that workflow
- **Index gap diagnosis requires Rails-side data cross-check** → coordinate с victory-session via `bin/claude-inbox send`

## Anti-patterns

- ❌ Hardcoded endpoint paths без verifying against this skill — see «NOT-working paths» table
- ❌ Burning recrawl quota на routine updates (price changes etc.) — sitemap handles those
- ❌ Log raw search-query text в shared logs / TG — privacy
- ❌ Skip quota check before POST — Yandex returns 429 + counts against limit anyway
- ❌ Use `popular-pages` / `indexing-history` endpoints — they 404; либо найти правильный path либо use sitemap diff
- ❌ Cache disabled на каждый kpi:phase_a run — burns API rate limit (have 12h cache)
- ❌ Pull > 500 queries at once — Yandex caps response anyway
