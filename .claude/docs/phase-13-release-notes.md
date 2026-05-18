# Phase 13 release notes — 18.05.26

**Tag:** `phase-13-final` = commit `0668472` (Iter 50 final)
**Tag:** `phase-13-cleanup` = commit `4bd7352` (post-audit cleanup)
**Branch:** `claude/currency-converter-app-9Ljw6`

## TL;DR

Закрыто **50 audit findings** (Phase 9-13, по 10 итераций каждая) в TG-боте АН «Виктори». Прод-смоук verified. Role handbook (12-15 стр PDF) доставлен команде в TG. Branch остаётся ahead main на 238 commits (continuous-deploy workflow); milestone закреплён через git tags.

## Cumulative scope: Phase 9-13 (50 итераций)

### Phase 9 — Foundation audit (iter 1-10)
- Authorization gaps в /stage, /note, /done, callbacks
- DLP regex completeness (SNILS, passport series)
- Race conditions: TaskBatch double-confirm, mark_completed, NC mkdir, ShareLink concurrent
- Idempotency: ClientDocument + ParserJob retry-safe
- LLM cost cap + cheaper :analysis fallbacks
- Topnlab transfer_client retry + crm_sync_failed flag
- Webhook dedup на update_id
- Digest async + remove double-work
- Observability: cost metrics + alerts + callback log gap

### Phase 10 — Operational gaps (iter 11-20)
- TG anti-spam, Sidekiq timezone confirmation
- NC fallback path для unlinked ClientDocument
- HTML escape audit (verified)
- TaskExtractor quality gate (skip garbled tasks)
- Topnlab OwnerSync — exclude soft-deleted + admin/staff phone collision

### Phase 11 — Management structure (iter 21-30)
- SLA stale assignee skip + manager escalate
- Lead reassignment notify previous owner
- `/reassign <task_id> @new_assignee` + DM обоим
- `/reopen <task_id>` undo done/canceled (24h window)
- `CriticalRecipients` cascade (directors → admins → managers)
- `AlertThrottle` Redis 5-min bucket
- `/deactivate @user` graceful offboarding
- `/resume_batch <id>` recover expired voice batch
- AssignTo callback structured audit log
- `/admin/health.json` operational status

### Phase 12 — Governance integrity (iter 31-40)
- `/promote` + `/link` sync role enum
- `/demote @user` manager revoke
- TaskBatch partial dispatch failure alert
- Stale inline buttons after `/reassign`
- `/stage` records actor в `metadata.stage_history`
- `/help` в groups DM-redirects
- `/admin/health` returns JSON 401 (not HTML 302)
- `TopicRegistry` validation + drift surfacing
- `LeadEvent.metadata` pruning via `append_history`
- `TaskExtractor` dedup identical tasks

### Phase 13 — Final hardening (iter 41-50)
- Director auth gate (`manager_or_director?`)
- `/assign` reject closed lead
- Voice batch concurrency guard
- `LeadAssignment.with_lock` race fix + idempotent same-target
- Tasks без assignee surface + post-approve DM warn
- TG `429 retry_after` honor (single retry)
- `crm_sync_error_history` (last 5) для pattern detection
- `AlertThrottle` suppressed counters в `/admin/health`
- `CriticalRecipients` tier visibility (Result struct + fallback tag)
- Topnlab API reachability в `/admin/health` (60s Redis cache)

## Smoke verification (18.05.26 19:02 MSK)

Все 10 Phase 13 итераций verified в 3 волны:

**Wave 1 — static (Ruby runner):** все 10 checks ✅
- `manager_or_director?` predicate работает для director/manager/agent
- Closed-lead reject: `success=false, msg="Лид уже закрыт..."`
- `refuse_pending_batch` method defined
- `@lead.with_lock` + idempotent same-target present
- Orphan task uncertainty + `handle_orphan_tasks` wired
- `api_call` accepts `retried:` kwarg
- `HISTORY_DEFAULT_CAPS[crm_sync_errors] = 5`
- `AlertThrottle.all_suppressed_summary` returns Hash
- `CriticalRecipients::Result` struct (tier=directors, fallback?=false, count=1)
- `/admin/health` checks include `:topnlab`

**Wave 2 — dynamic (rollback-safe transactions):** все 5 checks ✅
- Voice concurrency: synth pending batch detected
- `metadata['crm_sync_errors']` append (before=0 → after=1)
- AlertThrottle: 6× allow? → [true, false×5], suppressed_count=5
- Cascade fallback: all directors inactive → tier='managers', fallback?=true
- `operational_counters` keys complete (all 7)

**Wave 3 — HTTP endpoint:**
- `GET /admin/health.json` без token → 401 JSON ✅
- `GET /admin/health.json?token=$ADMIN_TOKEN` → 200, status="ok", all checks=true ✅

## Cleanup (commit `4bd7352`)

- 5× `.env.bak-*` файлов удалены (содержали ротированные токены)
- `.env.bak-*` в `.gitignore`
- `lib/tasks/phase13.rake` — diagnose/backfill_roles/prune_metadata (idempotent)
- `.claude/memory/progress.md` обновлён — Phase 9-13 history + Phase 14 backlog

Prod diagnose: 0 role-skew, 0 metadata bloat — фикс был preventive.

## Artifacts

- **Role handbook PDF** — 12-15 стр, кириллица OK, доставлен в @nick4man DM 18.05.26 (message_id 13). Source MD очищен. Cover + 3 секции по ролям (агент / менеджер / директор) + quick reference + troubleshooting + глоссарий.

## Phase 14 backlog (известные пробелы)

Detail в `.claude/memory/progress.md`. Приоритеты:
1. **MEDIUM** — `/stage` из closed → not-closed не блокируется (Iter 42 TODO)
2. **MEDIUM** — `BotCommandLog.error_message` column missing
3. **LOW** — Anchor message edit conflicts (multi-manager)
4. **LOW** — `TelegramUser#touch_from_message!` race
5. **LOW (cosmetic)** — `AdminTokenAuth` Devise coupling
6. **LOW (UX)** — Auto-cancel previous voice batch

Plus master-plan Phase 4-6 functionality (DocumentRequirement, StaffChatResponder, daily digests).

## Branch hygiene

Branch является continuous-deploy track (ahead main на 238 commits / 1045 files / 120K insertions). PR в main не оформляется — workflow прямого push'а в feature branch для прод-деплоя. Tags `phase-13-final` + `phase-13-cleanup` закрепляют milestone для future references.
