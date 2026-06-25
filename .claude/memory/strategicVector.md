# strategicVector.md — 24-month compass

> Резюме стратегического плана `.claude/plans/splendid-imagining-lerdorf.md`. Этот файл — то, что **должно быть в контексте каждой сессии** для согласования решений. Полный мастер-документ — там.

## North star (12 месяцев, май 2026 → май 2027)

1. **10-15 закрытых сделок в премиум-сегменте Рязани** (средний чек 15-60M ₽), доля рынка элит-сегмента ≥ 15%
2. **3-7 foreign-investor сделок** (земля/коммерция, средний чек 50-500M ₽)
3. **1500+ MAU** на сайте, ≥ 25% сессий с премиум-районов в Рязани
4. **Время «лид → договор» ≤ 14 дней** (отрасль 30-45)

## Три пиллара (фильтр для каждого решения)

1. **«Сделка под ключ»** — minimum движений клиента; всё через TG + cabinet
2. **«Глубокая экспертиза»** — investment audit + CMA + кейсы как контент
3. **«AI × человек»** — LLM для routine, человек для переговоров; цель: # сделок per agent ↑ 2-3x

## Фазы (timeline)

| Phase | Когда | Что |
|---|---|---|
| **A** — Ryazan elite capture | май 2026 → май 2027 (12 мес) | Топ-3 в премиум-сегменте Рязани |
| **B** — Foreign investors | always-on с мая 2026 | 3-7 сделок «иностранец → актив в РФ» |
| **C** — All-Russia federal | Q1 2027 → Q4 2027 | Топ-10 городов РФ |
| **D** — AI-conveyor | ongoing с мая 2026 | LLM в каждом routine-процессе |
| **E** — International | Q4 2027+ | Зарубежная диаспора + foreign-scale |

## Бюджетная позиция

**Гибрид** — free-first LLM chain через `Llm::OmniClient` (см. memory `feedback_llm_cost_economy`), paid escalation (Sonnet 4.6) только когда free провалил задачу + есть business justification.

Phase A burn: ~2.0-3.1M ₽/год. Break-even: 2-3 премиум-сделки (4-6 мес окупаемость).
Phase B burn: +1.0-1.5M ₽/год. Break-even: 1 сделка по земле/коммерции.

## Tech work — главные задачи

### Phase A (порядок приоритета — A1 первый)

- **A1** Premium-сегмент UI: фильтр + бэдж + `/premium` — `properties_controller.rb`
- **A2** Программные SEO landings (Солотча/Канищево/Дашково) — `landings_controller.rb` + `Seo::LandingGenerator` (LLM)
- **A3** Property dossier PDF (приватное предложение) — `property_dossier_pdf.rb` (Prawn)
- **A4** Видео-блок в карточке Property (YouTube/RuTube)
- **A5** TG personal-bot per лид — `telegram/client_bot/`
- **A6** Document collection через TG (OCR паспорт/ИНН/выписка) — `document_intake/` + Yandex Vision API
- **A7** Personal cabinet — `cabinet_controller.rb` + magic-link auth (НЕ Devise)
- **A8** Lookbook + Figma Code Connect production-ready
- **A9** Schema.org RealEstateListing enhance

### Phase B (параллельно)

- **B1** i18n EN landings + simplified catalog
- **B2** Investment-audit foreign mode (multi-currency + visa/legal chapter)
- **B3** Multi-currency price (RUB/USD/EUR/AED)
- **B4** EN-version chatbot + foreign-investor tools
- **B5** FATCA/CRS document intake
- **B6** Land-specific filtering (категория земли, ВРИ, кадастр)
- **B7** Visa/migration partner referral CTA

### Phase D (cross-cutting)

- Квалификация inbound лидов (бюджет/район/тип/hot-cold)
- Pre-meeting research (LLM brief по объекту)
- Draft договоров из шаблонов (LLM + manual review)
- Post-deal NPS + реферралы
- Internal QA звонков (Whisper + LLM)
- FAQ self-service (RAG над pgvector)

## Inter-agent coordination — расширение

К **10 имеющимся агентам** добавляются (создавать по мере необходимости спринтов):

| New agent | Domain | Phase |
|---|---|---|
| `client-onboarding-bot` | Document intake через TG + OCR + DLP | A6 |
| `contract-drafter` | LLM-черновики договоров | D |
| `foreign-investor-advisor` | EN/CN/TR/AR chat-flow для foreign clients | B4 |
| `market-analytics-publisher` | Еженедельные rapports по рынку | A контент |
| `case-study-writer` | Post-deal PDF + landing + видео-script | A pillar 2 |

К **5 имеющимся skills** добавляются:

| New skill | Trigger |
|---|---|
| `russian-real-estate-copywriting` | Любая user-facing копирайт-задача |
| `foreign-investor-playbook` | Запрос про land/commercial для иностранцев |
| `document-intake-validation` | OCR-результат → validated JSON |

Routing: `.claude/docs/delegation-map.md` (single source of truth) + `CLAUDE.md` + SessionStart hook.

## Orchestration patterns (kanonical)

```
Pattern 1 (Inbound lead):
TG/form → telegram-staff-bot-dev → client-onboarding-bot →
property-valuation-expert → contract-drafter → human → case-study-writer

Pattern 2 (New SEO landing):
seo-content-curator → market-analytics-publisher →
russian-real-estate-copywriting (skill) → test-bootstrapper

Pattern 3 (Foreign inquiry):
foreign-investor-advisor → property-valuation-expert (foreign-mode) →
pdf-report-designer → pdf-telegram-dispatcher
```

## Маркетинг / копирайт

**Tone-of-voice:** экспертный (конкретные цифры) + тёплый (вы, не ты; семейная метафора) + действие-ориентированный (конкретный CTA).

**Anti-patterns:** «ведущее агентство» без цифр; «эксклюзивные условия» без конкретики; эмодзи в SEO-meta; ВСЕ КАПС; канцелярит; англицизмы.

**SEO топология:**
```
/                  Brand + proofs + city
/premium           Манифест премиум-сегмента
/districts/[slug]  Программная по района
/buildings/[slug]  Программная по ЖК
/cases/[slug]      Post-deal анонимизированный кейс
/blog/[slug]       Экспертные лонгриды
/foreign           EN landing для иностранцев
/foreign/[country] Страна-специфичная
```

## Cross-cutting обязательства (нерушимые)

Эти 8 правил применяются всегда независимо от фазы:

1. Даты `dd.MM.yy` (skill `victory-rails-conventions`)
2. Enums с `_prefix: true` + русский в комментарии
3. Soft-delete `deleted_at` (без paranoia gem)
4. LLM cost economy — free-first chain
5. Сессия-домен split — Rails в victory, chatbot в chat, SEO в seo
6. 3 города уже current (Рязань + Москва + СПб) — не Phase 4
7. Nav: классический горизонтальный с dropdown'ами
8. Auth: Devise off; admin token; client cabinet — magic-link

## Что НЕ в скоупе (явно)

- Юридическая структура агентства (ИП vs ООО, налоги) — на стороне бизнеса
- HR-политики, стандарты найма
- Детальные финмодели CAC/LTV/Payback — отдельный артефакт
- Конкретные квартальные sprint plans — создаются по входу в спринт (избежать дрейфа)

## Infrastructure decision (04.06.26)

**Decision**: оставаться на Rails monolith + audit-engine sidecar (Python FastAPI). Не разбивать на микросервисы и не переходить на Kubernetes до конкретных trigger metrics. См. `splendid-imagining-lerdorf.md` секция «Strategic architecture assessment — 04.06.26».

**Rationale**:
- 55K LOC Rails app + 93 properties + 5 users + 1 разработчик + 4 AI sessions ≠ scale для микросервисов
- Audit-engine **уже** extracted где имело смысл (CPU-intensive Monte Carlo)
- Sidekiq queues = proper modular monolith (NOT coupling)
- K8s минимум $200/мес + 40-80ч setup + 4-8ч/мес maintenance vs **zero benefit** at current scale
- Strategic vector pillars (frictionless / expertise / AI×human): микросервисы neutral/negative, K8s negative. Worktree-fix для session coordination positive (Pillar 3).

**Trigger metrics — когда вернуться к re-evaluation** (когда **3 из 7** triggered):

| Metric | Current (04.06.26) | Threshold | Action |
|---|---|---|---|
| Property records | 93 | 500+ | Review sharding strategy |
| Article published | 47 | 10,000+ | Extract Article+embedding service |
| Concurrent users (daily peak) | <10 | 50+ | Add Sidekiq replicas |
| Inquiry/day | <1 | 20+ | Consider CRM extraction |
| Engineers (humans, не AI) | 1 | 3+ | Adopt feature-team-per-service |
| Multi-region (PoP) | RU only | Москва PoP added | K8s или managed alternative |
| Deploy cadence | weekly | hourly per-service | Independent deployments |

**Текущий счёт: 0/7**. Не делаем декомпозицию.

**Что делаем вместо**:
1. `git worktree` per Claude session — устраняет shared-filesystem collisions (см. session-coordination skill)
2. `main` = prod discipline (формализовать через CI gate + protected branch)
3. CI/CD baseline (rspec + rubocop + brakeman + bundler-audit на feature branches) — уже частично есть
4. Refactor hot-spots (Property model, dashboard controllers) через service-object pattern (NOT микросервисы)
5. Когда (если) Telegram bot или embedding pipeline разрастутся ≥ 500 LOC + own scale dynamics — extract по audit-engine pattern (Python/Rails sidecar + own DB/Redis + bridge network), НЕ K8s deployment.

## Subplans (создаются по факту входа в спринт)

Когда начинается каждая фаза/спринт — создаём отдельный subplan в `.claude/plans/`:

- **Phase A Sprint 1** (Q2 2026): premium UI + первые 5 SEO landings
- **Phase B Sprint 1** (Q2 2026): i18n EN + foreign chatbot
- **Phase D Sprint 1** (Q2-Q3 2026): квалификация лидов (chat_tools/qualify_lead.rb)

Не создаём заранее — устареют до начала исполнения.

## Полный документ

`.claude/plans/splendid-imagining-lerdorf.md` — 24-month compass с детальным разбором фаз, бюджетов, headcount, vendors, метрик.
