#!/usr/bin/env bash
# ОТКЛЮЧЁН 11.09.26. Синхронизация с openclaw запрещена.
#
# Раньше этот скрипт сверял каталог с боевой копией в
# /opt/.openclaw/.openclaw/workspace-conveyor/IT/scripts и умел лить файлы
# в обе стороны (--pull-vendored / --push-owned).
#
# Решение 11.09.26: openclaw (/opt/.openclaw/.openclaw/**) — АРХИВ. Только
# чтение, писать туда нельзя. Боевой код переехал в victory:
#
#   исходник  services/urgent-news-collector/   (источник правды)
#   боевой    /opt/victory-conveyor/            (деплой, git checkout из main)
#
# Обновить боевой каталог:  /opt/victory-conveyor/deploy.sh
# Подробности:              VENDOR.md, CLAUDE.md этого каталога

echo "sync-check.sh отключён 11.09.26: openclaw переведён в архив." >&2
echo "Деплой теперь: /opt/victory-conveyor/deploy.sh (см. VENDOR.md)." >&2
exit 2
