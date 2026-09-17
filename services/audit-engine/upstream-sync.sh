#!/usr/bin/env bash
# ОТКЛЮЧЁН 11.09.26. Re-pull из openclaw запрещён.
#
# Раньше тянул engine/ + stack/ + SKILL_API_CONTRACT.md с хоста `chat`
# из ~/.openclaw/workspace-it-dept/audit-engine-v2 и .../devops/audit-v2-stack.
#
# Решение 11.09.26: openclaw (/opt/.openclaw/.openclaw/**) — АРХИВ, только
# чтение. Вендоринг прекращён, victory — владелец кода audit-engine.
# Правки делаются здесь, в services/audit-engine/, и отсюда же деплоятся.
#
# Подробности — VENDOR.md рядом.

echo "upstream-sync.sh отключён 11.09.26: openclaw переведён в архив." >&2
echo "victory — владелец audit-engine, правь код здесь (см. VENDOR.md)." >&2
exit 2
