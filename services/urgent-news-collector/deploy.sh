#!/usr/bin/env bash
# Деплой конвейера новостей: git-репозиторий victory → боевой каталог.
#
#   ./deploy.sh              выкатить main (по умолчанию)
#   ./deploy.sh <ref>        выкатить конкретную ветку/тег/коммит
#
# Переменные:
#   VICTORY_REPO    где лежит репозиторий           (по умолчанию /opt/.openclaw/victory)
#   CONVEYOR_HOME   куда выкатывать                 (по умолчанию /opt/victory-conveyor)
#
# Что НЕ трогается: .env, logs/, notifications/, published/, .venv/.
# Удалённые из репозитория файлы в боевом каталоге не подчищаются —
# смотри вывод в конце и убирай руками.
#
# История: до 11.09.26 боевой копией был каталог внутри openclaw, а раскладкой
# занимался sync-check.sh --push-owned. openclaw переведён в архив, синк
# запрещён, единственный путь на прод — этот скрипт.

set -euo pipefail

REF="${1:-main}"
REPO="${VICTORY_REPO:-/opt/.openclaw/victory}"
DEST="${CONVEYOR_HOME:-/opt/victory-conveyor}"

case "$DEST" in
  /opt/.openclaw/.openclaw/*)
    echo "отказ: $DEST внутри архива openclaw — туда не пишем (решение 11.09.26)" >&2
    exit 2 ;;
esac

[ -d "$REPO/.git" ] || { echo "не репозиторий: $REPO" >&2; exit 2; }
git -C "$REPO" rev-parse --verify --quiet "$REF^{commit}" >/dev/null \
  || { echo "нет такой ревизии: $REF" >&2; exit 2; }

SHA="$(git -C "$REPO" rev-parse --short "$REF")"
echo "→ выкатываю $REF ($SHA) из $REPO в $DEST"

mkdir -p "$DEST"/{logs,notifications,published}

# Скрипты конвейера.
git -C "$REPO" archive "$REF:services/urgent-news-collector" | tar x -C "$DEST"
# Зеркало на сайт — живёт в соседнем сервисе, но деплоится рядом (MIRROR_SCRIPT).
git -C "$REPO" archive "$REF:services/chat-host-cron" post_news_to_victory.sh | tar x -C "$DEST"
chmod +x "$DEST/post_news_to_victory.sh" "$DEST/deploy.sh"

# venv: создаём при первом деплое, дальше только доставляем зависимости.
if [ ! -x "$DEST/.venv/bin/python3" ]; then
  echo "→ создаю venv"
  python3 -m venv "$DEST/.venv"
fi
"$DEST/.venv/bin/pip" install --quiet --upgrade pip
"$DEST/.venv/bin/pip" install --quiet -r "$DEST/requirements.txt"

if [ ! -f "$DEST/.env" ]; then
  echo "⚠ нет $DEST/.env — скопируй .env.example и заполни, иначе конвейер не стартует"
fi

echo "$SHA  $(date '+%d.%m.%y %H:%M')  $REF" >> "$DEST/deployed.log"
echo "✓ готово. Ревизия: $SHA"
"$DEST/.venv/bin/python3" -c "import feedparser, psycopg2, requests; print('✓ зависимости на месте')"
