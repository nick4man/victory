# Phase 14 release notes — 18.05.26

**Tag:** `phase-14-final` = commit `2f7143a` (Iter 56 final)
**Branch:** `claude/currency-converter-app-9Ljw6`
**Cumulative:** Phase 9-14 = **56 audit iterations**

## TL;DR

Закрыты все 6 known bugs из Phase 13 Explore backlog (Iter 51-56). Прод-смоук verified в 2 волны, `/admin/health` показывает `status: ok` без регрессий. Phase 13 + 14 вместе = 56 итераций аудита TG work-bot завершены.

## Iter 51-56 scope

### Iter 51 — `/stage` reject re-open closed lead (MEDIUM)
Симметрия с Phase 13 Iter 42. До фикса `/stage показ` на лиде в `closed_won` возвращал его в активный pipeline — повторный `first_contact_at`, ломал KPI. Теперь `LeadStageTransition` отклоняет `closed_*` → не-`closed_*` transitions. `closed_won ↔ closed_lost` остаются разрешены (admin-override на ошибку финального решения без бэкенд-доступа).

### Iter 52 — `BotCommandLog.error_message` column (MEDIUM)
Migration `AddErrorMessageToBotCommandLogs` добавил `error_message:text`. `CallbacksRouter#log_audit` теперь принимает `error_message:` kwarg + truncate(500). Existing whoami/whoami_force/assign_to пишут error в args (backward compat) — Phase 15+ может перевести на structured column.

### Iter 53 — Anchor edit race wrap (LOW)
Multiple managers concurrent `edit_message_text` на одном якоре → last-write-wins. Phase 13 Iter 44 (`LeadAssignment.with_lock`) частично mitigates. Iter 53 расширяет to:
- **LeadStageTransition** — wrap `#call` в `@lead.with_lock` + reload + idempotent already-at guard
- **SpamCallback** — wrap mutation + idempotent `spam_marked_by` skip
- **HashtagHandler** — wrap priority-flip + anchor edit; notify_managers остаётся outside lock (TG calls долгие)

`AnchorMigrator` уже имел `with_lock` (Phase 9 vintage).

### Iter 54 — TelegramUser.touch_from_message race (LOW)
`update_columns` без lock → parallel inbound messages могли race username/dm_chat_id. Fix: `with_lock` + `reload` + recompute changes внутри блока. Hot path (каждое TG-message), но pessimistic row-lock не блокирует other users.

### Iter 55 — AdminTokenAuth Devise decoupling (LOW cosmetic)
Concern использовал `respond_to?(:user_signed_in?)` для определения Devise-state — хрупко при выпиле Devise. Fix: единый predicate `devise_present?` = `defined?(Devise) && respond_to?(:user_signed_in?)`. Fallback `redirect_to` теперь choose `new_user_session_path` (если Devise) OR `/admin/login` (наш token-cookie endpoint).

### Iter 56 — Voice batch one-click cancel UX (LOW UX)
Phase 13 Iter 43 reject-only MVP требовал 3 шага (скролл → click cancel → re-record). Iter 56 enhances `refuse_pending_batch` reply с inline-кнопкой `[✖️ Отменить старый #N и попробовать снова]`. `callback_data` reuses `batch_confirm:<id>:cancel` prefix — TaskBatchConfirmCallback уже handles cancel action. One-click.

## Smoke verification (18.05.26)

**Wave A — статика + dynamic:** все 6 checks ✅
- Iter 51: `closed_won → show` → `success=false, msg="Re-open запрещён"`. `closed_won → closed_lost` → `success=true` (admin override allowed).
- Iter 52: `BotCommandLog.column_names.include?('error_message') = true`. Sample assign works.
- Iter 53: `with_lock do` present в всех 3 файлах (lead_stage_transition, spam_callback, hashtag_handler).
- Iter 54: `touch_from_message!` source contains `with_lock do` + `reload`.
- Iter 55: `devise_present?` method defined, used in `require_admin_access` + `devise_admin?`, fallback `/admin/login` present.
- Iter 56: `refuse_pending_batch` content has `inline_keyboard` + `batch_confirm:<id>:cancel` + `Отменить старый`. `TaskBatchConfirmCallback` case-when `'cancel'` → `batch.cancel!` confirmed.

**Live HTTP:**
- `GET /admin/health.json?token=$ADMIN_TOKEN` → 200 OK
- `status: "ok"`, checks={db: true, redis: true, sidekiq: true, topnlab: true}
- No regressions vs Phase 13 baseline

**Dynamic lock smoke:**
- `LeadEvent#69.with_lock { reload }` runs cleanly — pattern reachable

## Phase 15+ backlog

| Item | Type | Notes |
|---|---|---|
| `BotCommandLog.error_message` populate в всех call-sites | MEDIUM | Iter 52 column добавлен, CallbacksRouter wired; whoami/whoami_force/assign_to embedded в args (backward compat) — refactor для structured queries |
| TaskBatch retry-dispatch | MEDIUM | Iter 33 persists failures в parsed_payload — `/retry_dispatch <batch_id>` для re-DM |
| Backfill `stage_history` initial entry для pre-Iter-35 leads | LOW | Existing leads имеют пустой `stage_history` |
| `TopicRegistry.record_discovery` persist в YAML (не только Redis) | LOW | Restart теряет discoveries |

Plus master-plan Phase 4-6 functionality (DocumentRequirement, StaffChatResponder, daily digests) — не аудит.

## Branch hygiene

Branch остаётся continuous-deploy (ahead main на ~245 commits). PR не оформляется. Tags:
- `phase-13-final` → `0668472`
- `phase-13-cleanup` → `4bd7352`
- `phase-14-final` → `2f7143a`
