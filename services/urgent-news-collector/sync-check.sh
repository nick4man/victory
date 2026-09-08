#!/usr/bin/env bash
# Сверяет этот каталог с БОЕВОЙ копией конвейера и выкладывает туда изменения.
#
# Владелец всех файлов — victory (см. SERVICE.md). Забирать оттуда нечего:
# openclaw-репозиторий с 07.09.26 архив, напрямую не правится. Каталог, с
# которым идёт сверка, — не второй источник правды, а продакшен: оттуда крон
# запускает конвейер.
#
#   ./sync-check.sh           только отчёт; exit 1 если боевая копия отстала
#   ./sync-check.sh --deploy  выложить наши файлы в боевой каталог
#
# Путь к боевому каталогу переопределяется через CONVEYOR_SCRIPTS_DIR.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPSTREAM="${CONVEYOR_SCRIPTS_DIR:-/opt/.openclaw/.openclaw/workspace-conveyor/IT/scripts}"

# Всё, что деплоится. Общая инфраструктура конвейера (pipeline_utils,
# content_db_utils) с 07.09.26 в этом же списке: она наша.
DEPLOYED=(urgent_collector.py urgent_trigger.py urgent_relevance.py
          test_urgent_relevance.py backtest_urgent_relevance.py
          pipeline_utils.py content_db_utils.py)

MODE="${1:-check}"
case "$MODE" in
  check|--deploy) ;;
  --push-owned)
    echo "флаг --push-owned переименован в --deploy (07.09.26)" >&2
    MODE="--deploy"
    ;;
  --pull-vendored)
    echo "режима --pull-vendored больше нет: боевой каталог — цель деплоя," >&2
    echo "а не источник правды. Подробности — VENDOR.md и SERVICE.md." >&2
    exit 2
    ;;
  *) echo "неизвестный флаг: $MODE (см. шапку файла)" >&2; exit 2 ;;
esac

if [[ ! -d "$UPSTREAM" ]]; then
  echo "боевой каталог не найден: $UPSTREAM" >&2
  echo "задай CONVEYOR_SCRIPTS_DIR, если конвейер на другой машине" >&2
  exit 2
fi

drift=0

report() {
  local f="$1"
  local mine="$SCRIPT_DIR/$f" theirs="$UPSTREAM/$f"
  if [[ ! -f "$theirs" ]]; then
    printf '  %-32s НЕТ в боевом каталоге\n' "$f"; drift=1; return
  fi
  if diff -q "$mine" "$theirs" >/dev/null 2>&1; then
    printf '  %-32s ok\n' "$f"
  else
    printf '  %-32s боевая копия отстала\n' "$f"
    drift=1
  fi
}

echo "боевой каталог (цель деплоя): $UPSTREAM"
echo
echo "наши файлы — victory источник правды для всех:"
for f in "${DEPLOYED[@]}"; do report "$f"; done
echo

case "$MODE" in
  --deploy)
    for f in "${DEPLOYED[@]}"; do cp -v "$SCRIPT_DIR/$f" "$UPSTREAM/$f"; done
    echo
    echo "выложено. Коммитить там ничего не нужно: репозиторий openclaw — архив."
    ;;
  check)
    if (( drift )); then
      echo "боевая копия отстала. Выложить: ./sync-check.sh --deploy"
      exit 1
    fi
    echo "расхождений нет."
    ;;
esac
