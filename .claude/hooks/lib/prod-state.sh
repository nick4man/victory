#!/usr/bin/env bash
# .claude/hooks/lib/prod-state.sh — общие функции про состояние прода.
#
# Зачем: GitHub не знает, что стоит на проде. Мерж в main и выкатка — события
# независимые (деплой ручной), поэтому «в main» и «на сайте» расходятся молча.
# 07.09.26 прод отставал на 33 коммита, и выяснилось это случайно.
#
# Источник правды — ветка `prod` на origin: её двигает bin/prod-mark после
# успешной выкатки. Ветку тянет обычный `git fetch`, а .git у всех worktree
# общий (~/victory/.git), поэтому один fetch обновляет состояние сразу
# для всех сессий — отдельный транспорт не нужен.
#
# Подключение: . .claude/hooks/lib/prod-state.sh
# Все функции безопасны при отсутствии сети, ref'а и прод-чекаута.

# Не тянуть чаще, чем раз в PROD_FETCH_TTL секунд: сессий несколько, старты
# идут пачками, и каждый раз ходить в сеть незачем.
PROD_FETCH_TTL="${PROD_FETCH_TTL:-300}"
PROD_FETCH_TIMEOUT="${PROD_FETCH_TIMEOUT:-8}"

# Локальный прод-чекаут — есть только на хосте, где живёт прод.
PROD_DIR="${VICTORY_PROD_DIR:-/home/q/victory}"

# Обновить refs, если давно не обновляли. Никогда не блокирует и не падает:
# сеть может лежать, а старт сессии от этого зависеть не должен.
prod_fetch_if_stale() {
  local common fetch_head age
  common=$(git rev-parse --git-common-dir 2>/dev/null) || return 0
  fetch_head="$common/FETCH_HEAD"

  if [ -f "$fetch_head" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$fetch_head" 2>/dev/null || echo 0) ))
    [ "$age" -lt "$PROD_FETCH_TTL" ] && return 0
  fi

  timeout "$PROD_FETCH_TIMEOUT" git fetch --quiet origin >/dev/null 2>&1 || true
  return 0
}

# SHA выкаченного коммита по отметке в origin. Пусто, если отметки нет.
prod_sha() {
  git rev-parse --verify --quiet origin/prod 2>/dev/null || true
}

# SHA прод-чекаута напрямую — точнее отметки, но работает лишь на прод-хосте.
# Нужен, чтобы поймать случай «выкатили, но bin/prod-mark не запустили».
prod_local_sha() {
  [ -d "$PROD_DIR/.git" ] || [ -f "$PROD_DIR/.git" ] || return 0
  git -C "$PROD_DIR" rev-parse HEAD 2>/dev/null || true
}

# Однострочное описание коммита: короткий SHA + заголовок.
prod_describe() {
  local sha="$1"
  [ -n "$sha" ] || return 0
  git log -1 --format='%h %s' "$sha" 2>/dev/null || echo "${sha:0:7} (коммита нет локально)"
}

# Сколько коммитов main впереди указанного — то есть сколько ждёт выкатки.
# Пусто, если посчитать нельзя (нет ref'а или нет общей истории).
prod_commits_ahead() {
  local base="$1"
  [ -n "$base" ] || return 0
  git rev-parse --verify --quiet origin/main >/dev/null 2>&1 || return 0
  git rev-list --count "$base..origin/main" 2>/dev/null || true
}

# Отстаёт ли текущая ветка от main.
prod_branch_behind_main() {
  git rev-parse --verify --quiet origin/main >/dev/null 2>&1 || return 0
  git rev-list --count HEAD..origin/main 2>/dev/null || true
}
