#!/usr/bin/env bash
# .claude/hooks/lib/prod-state.sh — общие функции про состояние прода.
#
# Зачем: GitHub не знает, что стоит на проде. Мерж в main и выкатка — события
# независимые (деплой ручной), поэтому «в main» и «на сайте» расходятся молча.
# 07.09.26 прод отставал на 33 коммита, и выяснилось это случайно.
#
# Источник правды — ветка `prod` на origin: её двигает bin/prod-mark после
# успешной выкатки. Ветку тянет обычный `git fetch`, а .git у всех worktree
# общий (`<main checkout>/.git`), поэтому один fetch обновляет состояние сразу
# для всех сессий — отдельный транспорт не нужен.
#
# Подключение: . .claude/hooks/lib/prod-state.sh
# Все функции безопасны при отсутствии сети, ref'а и прод-чекаута.

# Не тянуть чаще, чем раз в PROD_FETCH_TTL секунд: сессий несколько, старты
# идут пачками, и каждый раз ходить в сеть незачем.
PROD_FETCH_TTL="${PROD_FETCH_TTL:-300}"
PROD_FETCH_TIMEOUT="${PROD_FETCH_TIMEOUT:-8}"

# Кандидат в прод-чекаут: main checkout ЭТОЙ машины. Прод он или нет, решает
# prod_is_prod_host ниже — сам по себе main checkout есть у всех. Путь
# вычисляем из git, а не
# хардкодим: репозиторий живёт на двух хостах с разными корнями, а функции ниже
# зовут из любого worktree, в том числе вложенного. `--git-common-dir` даёт
# `<main checkout>/.git` (в самом main checkout — относительный `.git`), значит
# родитель и есть нужный каталог. VICTORY_PROD_DIR — приоритетный override.
# `pwd -P` — физический путь: его сравнивают с `git rev-parse --show-toplevel`,
# который физический всегда, и логический путь через симлинк не совпал бы.
prod_main_checkout() {
  local common
  common=$(git rev-parse --git-common-dir 2>/dev/null) || return 0
  (CDPATH='' cd -- "$common/.." 2>/dev/null && pwd -P) || return 0
}

PROD_DIR="${VICTORY_PROD_DIR:-$(prod_main_checkout)}"

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

# Этот ли хост — прод. Раньше ответ давал сам факт существования
# `/home/q/victory`: хардкод и был признаком прод-хоста. Теперь PROD_DIR
# вычисляется и указывает на main checkout ЛЮБОЙ машины, поэтому признак нужен
# явный, иначе облачная сессия, Codespaces, CI и клон любого разработчика
# получают «Отметка врёт» про прод, которого у них нет.
#
# Два признака, оба дешёвые:
#   1. VICTORY_PROD_DIR задан руками — значит вызывающий сам объявил каталог;
#   2. в чекауте лежит маркер .victory-prod — его создаёт bin/prod-mark после
#      успешной отметки, а он запускается только на прод-хосте.
# Маркер не отслеживается git (см. .gitignore): он про машину, а не про код.
#
# Пока маркера нет, сверка молчит. Это намеренно: молчание хуже ложной тревоги
# только на самом прод-хосте, и лечится оно первым же прогоном bin/prod-mark,
# тогда как ложная тревога била бы по всем остальным машинам сразу.
prod_is_prod_host() {
  [ -n "${VICTORY_PROD_DIR:-}" ] && return 0
  [ -n "$PROD_DIR" ] && [ -f "$PROD_DIR/.victory-prod" ]
}

# SHA прод-чекаута напрямую — точнее отметки, но работает лишь на прод-хосте.
# Нужен, чтобы поймать случай «выкатили, но bin/prod-mark не запустили».
prod_local_sha() {
  [ -n "$PROD_DIR" ] || return 0
  prod_is_prod_host || return 0
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
