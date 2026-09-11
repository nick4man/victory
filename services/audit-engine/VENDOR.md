# Audit Engine v2.0 — код наш

**Решение 11.09.26: вендоринг прекращён.** openclaw
(`/opt/.openclaw/.openclaw/**`) переведён в архив — только чтение, писать туда
нельзя. `upstream-sync.sh` отключён и отказывается запускаться; запрет
продублирован в `.claude/settings.json`. Источник правды для кода движка —
этот каталог.

Раньше здесь лежала вендорная копия `audit-engine-v2` (FastAPI: Efficiency
Index, Monte Carlo, гедонистическая регрессия, PDF-отчёты), которую тянули
с хоста `chat`.

## Бывший upstream (только история)

- Хост: `chat` (192.168.0.105); на этой машине — архив `/opt/.openclaw/.openclaw`
- Движок — `workspace-it-dept/audit-engine-v2/`
- Стек — `workspace-it-dept/devops/audit-v2-stack/`
- Контракт API — `skills/audit-engine-v2-api/SKILL.md`
- Импортировано: 11.05.26. Вендоринг закрыт: 11.09.26

## Состояние на момент заморозки

Копия в victory **опередила архив**: здесь есть то, чего в архиве нет —
`api/auth.py`, роутеры `jobs.py` / `search.py` / `developers.py`,
`jobs/scheduler.py`, `parsers/developer_risk.py`, три alembic-миграции
(`i7e8d4f3a9c1`, `j8f5e6a7b9c2`, `k9a6b7c8d2e3`), `scripts/check_cron_health.py`.
Расхождений всего ~38 позиций, встречное направление — только
`data/templates` и правки в `docker-compose.yml` (архив правили 07.09.26).

🚨 **Живой контейнер пока поднят из архива.** `docker inspect audit-v2-api`
показывает compose-project-dir
`/opt/.openclaw/.openclaw/workspace-it-dept/devops/audit-v2-stack`, то есть прод
запущен НЕ из этого каталога. Переезд стека не сделан: смена рабочего каталога
меняет имя compose-проекта, а с ним и имена томов (`audit-v2-stack_reports`) —
без `name:` в compose или объявления томов external это тихая потеря данных.
Делать отдельным шагом, с проверкой томов.

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
