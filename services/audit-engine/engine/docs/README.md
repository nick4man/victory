# audit-engine-v2 — docs

Канонический API-контракт живёт **не здесь**, а в SKILL-файле конвейера:

→ [`/skills/audit-engine-v2-api/SKILL.md`](../../../skills/audit-engine-v2-api/SKILL.md)

Там описаны все 24 HTTP-ручки, payload-ы по каждому `PropertyType`, правила
использования, roles-mapping (какой агент с какими ручками работает) и
операционные гейты.

## Правило синхронизации

Любое изменение эндпоинта (новая ручка, смена query-параметра, изменение
ответа) в `src/audit_engine/api/` **обязано** в том же PR обновлять
`skills/audit-engine-v2-api/SKILL.md`. PR без синхронизации блокируется
`it-debugger`-ом на верификационной итерации.

## Операционный контракт

Deploy, rollback, миграции, smoke-тесты, типовые ошибки — см.
[`/workspace-it-dept/devops/audit-v2-stack/RUNBOOK.md`](../../devops/audit-v2-stack/RUNBOOK.md).
