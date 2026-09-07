#!/usr/bin/env bash
# Сверяет этот каталог с боевой копией конвейера (openclaw/workspace-conveyor).
# Направления НЕ симметричны — кто чем владеет, см. VENDOR.md.
#
#   ./sync-check.sh                  только отчёт; exit 1 если есть расхождения
#   ./sync-check.sh --pull-vendored  забрать pipeline_utils.py + content_db_utils.py из openclaw
#   ./sync-check.sh --push-owned     положить файлы коллектора в боевой каталог
#
# Путь к боевому каталогу переопределяется через CONVEYOR_SCRIPTS_DIR.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPSTREAM="${CONVEYOR_SCRIPTS_DIR:-/opt/.openclaw/.openclaw/workspace-conveyor/IT/scripts}"

OWNED=(urgent_collector.py urgent_trigger.py urgent_relevance.py
       test_urgent_relevance.py backtest_urgent_relevance.py)
VENDORED=(pipeline_utils.py content_db_utils.py)

MODE="${1:-check}"
case "$MODE" in
  check|--pull-vendored|--push-owned) ;;
  *) echo "неизвестный флаг: $MODE (см. шапку файла)" >&2; exit 2 ;;
esac

if [[ ! -d "$UPSTREAM" ]]; then
  echo "боевой каталог не найден: $UPSTREAM" >&2
  echo "задай CONVEYOR_SCRIPTS_DIR, если конвейер на другой машине" >&2
  exit 2
fi

drift=0

report() { # $1=файл $2=владелец $3=направление-починки
  local f="$1" owner="$2" fix="$3"
  local mine="$SCRIPT_DIR/$f" theirs="$UPSTREAM/$f"
  if [[ ! -f "$theirs" ]]; then
    printf '  %-32s НЕТ в боевом каталоге\n' "$f"; drift=1; return
  fi
  if diff -q "$mine" "$theirs" >/dev/null 2>&1; then
    printf '  %-32s ok\n' "$f"
  else
    printf '  %-32s РАСХОЖДЕНИЕ (владелец: %s → %s)\n' "$f" "$owner" "$fix"
    drift=1
  fi
}

echo "боевой каталог: $UPSTREAM"
echo
echo "наши файлы (victory — источник правды):"
for f in "${OWNED[@]}"; do report "$f" victory "--push-owned"; done
echo
echo "вендор (openclaw — источник правды, здесь не править):"
for f in "${VENDORED[@]}"; do report "$f" openclaw "--pull-vendored"; done
echo

case "$MODE" in
  --pull-vendored)
    for f in "${VENDORED[@]}"; do cp -v "$UPSTREAM/$f" "$SCRIPT_DIR/$f"; done
    echo
    echo "готово. Проверь diff и закоммить в victory:  git diff services/urgent-news-collector/"
    ;;
  --push-owned)
    for f in "${OWNED[@]}"; do cp -v "$SCRIPT_DIR/$f" "$UPSTREAM/$f"; done
    echo
    echo "готово. Изменения лежат в рабочей копии openclaw — коммить их там же."
    ;;
  check)
    if (( drift )); then
      echo "есть расхождения. Чинить: --pull-vendored (вендор) / --push-owned (наши файлы)"
      exit 1
    fi
    echo "расхождений нет."
    ;;
esac
