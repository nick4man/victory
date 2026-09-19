#!/usr/bin/env bash
# postStartCommand: отрабатывает при каждом пробуждении Codespace.
#
# Песочницу карточек CRM будит /starttest из боевого бота, и человека у
# терминала в этот момент нет — значит, web, sidekiq и опрос тестового бота
# должны подняться сами. Скрипт идемпотентный: уже запущенное не трогает.
set -uo pipefail
cd /workspaces/victory || exit 0
[ -x bin/sandbox-codespace ] || exit 0
[ -r /workspaces/.codespaces/shared/user-secrets-envs.json ] || exit 0

bin/sandbox-codespace up 2>&1 | tail -3
