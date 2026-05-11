# Vendored: СОДИКС Audit Engine v2.0

This is a **vendored copy** of `audit-engine-v2` — a FastAPI-based property
investment audit engine (Efficiency Index, Monte Carlo, hedonic regression,
PDF reports). It is **not** developed in this repository; the canonical source
lives elsewhere.

## Source

- **Upstream host**: `chat` SSH alias (192.168.0.105)
- **Upstream paths**:
  - Engine source — `~/.openclaw/workspace-it-dept/audit-engine-v2/`
  - Devops stack — `~/.openclaw/workspace-it-dept/devops/audit-v2-stack/`
  - API contract — `~/.openclaw/skills/audit-engine-v2-api/SKILL.md`
- **Imported at**: 2026-05-11
- **Upstream owner**: СОДИКС ИТ-Департамент (chat:agents/devops-engineer)
- **Upstream contact**: ask via chat-server `realtor-assistant` agent

## Tree layout

```
services/audit-engine/
├── VENDOR.md              # this file
├── SKILL_API_CONTRACT.md  # 24-endpoint REST API contract (read-only)
├── upstream-sync.sh       # re-pull from chat, manual trigger
├── engine/                # FastAPI source — DO NOT EDIT in-tree
│   ├── pyproject.toml
│   ├── alembic.ini
│   ├── Dockerfile.api
│   ├── src/audit_engine/  # 60 Python files
│   ├── migrations/        # 12 alembic versions
│   ├── scripts/           # seed_bank_offers.py etc.
│   ├── templates/         # PDF templates (WeasyPrint)
│   ├── tests/
│   └── data/
└── stack/                 # docker-compose, smoke payloads, runbook
    ├── docker-compose.yml
    ├── docker-compose.cpu.yml   # CPU-only override (our default)
    ├── Dockerfile.api
    ├── RUNBOOK.md
    ├── smoke_apartment.json
    └── *.sh helpers
```

## Editing rules

**DO NOT** edit files inside `engine/` or `stack/` directly. The integration
contract is: patch upstream → re-run `upstream-sync.sh` → review the diff.

The reason: this tree is overwritten on every sync. Local-only patches are
silently lost on the next pull. If you need to change engine behavior,
either:

1. Patch upstream first (ask the chat-team via `realtor-assistant`), then sync.
2. Override via env vars or `docker-compose.audit.yml` (the override compose
   file IS owned by this repo).
3. For Rails-side adaptations (request/response shape, retries, fallbacks),
   patch `app/services/audit_engine/` — that's our code.

## Sync procedure

```bash
cd services/audit-engine
./upstream-sync.sh
git -C ../.. diff --stat services/audit-engine/
```

After review, commit with a message describing the upstream version/date.

## Build & run

See `services/audit-engine/stack/RUNBOOK.md` for ops contract (deploy,
rollback, smoke). The integration into victory62's docker-compose lives at
`docker-compose.audit.yml` in the repo root.

## Image pinning

To prevent silent image changes on engine source re-sync, pin the built
image by digest in `docker-compose.audit.yml`:

```yaml
audit-api:
  image: viktory-audit-engine:v2.0@sha256:<digest>
```

Re-build only when intentionally upgrading; capture the new digest in the
same commit.

## What's NOT vendored

- `RUNBOOK_SECRETS.md` — excluded from sync (contains credentials).
- `__pycache__`, `.pytest_cache`, `*.egg-info`, `*.pyc` — build artifacts.
- `.venv` / `venv` — local dev environments.

## License & provenance

Closed-source internal tool. Used here under direct authorization from the
upstream owner. Do not redistribute outside victory62 deployments.
