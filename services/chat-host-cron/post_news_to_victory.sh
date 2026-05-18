#!/usr/bin/env bash
# Push a single news item from chat-host CREATIVE pipeline → victory62 /news.
#
# Drop this script on chat-host at:
#   /opt/.openclaw/.openclaw/workspace-conveyor/IT/scripts/post_news_to_victory.sh
# Then add ONE line at the end of urgent_trigger.py and weekly_digest_trigger.py
# (or as a separate cron-step) that calls:
#
#   bash post_news_to_victory.sh <meta_json_path> <text_md_path>
#
# Env required (set in ~/.bashrc or systemd unit on chat-host):
#   VICTORY_NEWS_TOKEN  — must match NEWS_INGEST_TOKEN in victory62 .env
#   VICTORY_NEWS_URL    — endpoint, default https://victory62.org/webhooks/news_ingest
#
# Idempotent: re-posting the same meta.event_id updates the existing article
# rather than creating a dup. Safe to retry on transient errors.

set -euo pipefail

META="${1:?usage: $0 <meta_json_path> <text_md_path>}"
TEXT="${2:?usage: $0 <meta_json_path> <text_md_path>}"
TOKEN="${VICTORY_NEWS_TOKEN:?env VICTORY_NEWS_TOKEN required}"
ENDPOINT="${VICTORY_NEWS_URL:-https://victory62.org/webhooks/news_ingest}"

[ -f "$META" ] || { echo "meta missing: $META" >&2; exit 2; }
[ -f "$TEXT" ] || { echo "text missing: $TEXT" >&2; exit 2; }

# urgent_*.txt vs digest_*.txt — derive source tag from filename prefix.
case "$(basename "$META")" in
  urgent_*) SOURCE="chat_urgent" ;;
  digest_*) SOURCE="chat_digest" ;;
  *)        SOURCE="chat_urgent" ;;
esac

# Build payload via jq — pull headline + hashtags from meta, body from .txt.
# Strip trailing hashtag-only paragraph from body (chat-host appends it at the
# bottom for Telegram; on the site we render hashtags from the `hashtags`
# array instead of duplicating them inside the article body).
STRIPPED_BODY=$(python3 - "$TEXT" <<'PYEOF'
import sys, re
text = open(sys.argv[1], "r", encoding="utf-8").read().rstrip()
text = re.sub(r"\n\s*\n\s*(?:#[\wА-Яа-яЁё_]+\s*)+\s*$", "", text)
sys.stdout.write(text)
PYEOF
)

# Fallbacks: digest pipelines write meta WITHOUT event_id/headline keys
# (they use short_summary + week_start/end). Urgent pipelines DO write them.
# Без fallbacks digest всегда падает с http=422 "title required".
EID=$(jq -r '.event_id // empty' "$META")
[ -z "$EID" ] && EID=$(basename "$META" .meta.json)
TITLE=$(jq -r '.headline // .short_summary // ""' "$META")

PAYLOAD=$(jq -n \
  --arg eid    "$EID" \
  --arg src    "$SOURCE" \
  --arg title  "$TITLE" \
  --arg body   "$STRIPPED_BODY" \
  --argjson tags "$(jq '.hashtags // []' "$META")" \
  --arg pub    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg src_url "$(jq -r '.source_url // ""' "$META")" \
  --arg tg_url    "https://t.me/rznvictory" \
  --arg tg_handle "@rznvictory" \
  '{
    external_id:     ($eid // null),
    external_source: $src,
    title:           $title,
    body_md:         $body,
    hashtags:        $tags,
    category:        "news",
    schema_type:     "NewsArticle",
    published_at:    $pub,
    source_url:      (if $src_url == "" then null else $src_url end),
    telegram_channel_url:    $tg_url,
    telegram_channel_handle: $tg_handle
  } | with_entries(select(.value != null))')

# Retry transient failures (5xx, network) up to 3 times with backoff.
attempt=1
while [ $attempt -le 3 ]; do
  HTTP=$(curl -sS -o /tmp/news_ingest_resp.json -w "%{http_code}" \
           -X POST \
           -H "Authorization: Bearer $TOKEN" \
           -H "Content-Type: application/json" \
           --data "$PAYLOAD" \
           --max-time 20 \
           "$ENDPOINT" || echo "000")
  if [[ "$HTTP" =~ ^2 ]]; then
    URL=$(jq -r '.url // empty' /tmp/news_ingest_resp.json 2>/dev/null || true)
    ARTICLE_ID=$(jq -r '.article_id // empty' /tmp/news_ingest_resp.json 2>/dev/null || true)
    ACTION=$(jq -r '.action // empty' /tmp/news_ingest_resp.json 2>/dev/null || true)
    echo "[news_ingest] OK $HTTP $ACTION #$ARTICLE_ID $URL" >&2
    if [ -n "$URL" ]; then
      printf '%s\n' "$URL"
    fi
    exit 0
  fi
  echo "[news_ingest] attempt $attempt http=$HTTP body=$(head -c 200 /tmp/news_ingest_resp.json 2>/dev/null)" >&2
  sleep $((attempt * 5))
  attempt=$((attempt + 1))
done

echo "[news_ingest] FAILED after 3 attempts" >&2
exit 1
