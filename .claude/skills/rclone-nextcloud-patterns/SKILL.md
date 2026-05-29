---
name: rclone-nextcloud-patterns
description: Use when working with the corporate Nextcloud at `cloud.victory62.org` via local rclone remote `nxt:` (WebDAV backend, single remote). Captures the directory taxonomy (5 root dirs + 15 `Офис/` subdirs with sensitivity tiers, deep НЕДВИЖИМОСТЬ subtree), deal-folder naming convention (`<TopnlabID> <ДЕЙСТВИЕ> <descriptor> <ClientFirstName>`), save-routing matrix, share-link workflow (rclone link doesn't work — OCS API or manual UI), backup-before-overwrite discipline, Cyrillic quoting gotchas. Full inventory: `.claude/docs/nextcloud-cheatsheet.md`. RELATED (.claude/docs/delegation-map.md) — pair with agent `nextcloud-rclone-ops` for actual execution; coordinate with agents `case-study-writer`/`client-onboarding-bot`/`pdf-report-designer` для proper save destinations (см. hand-off destinations таблицу).
---

# rclone Nextcloud — patterns + safety

Apply when reading from / writing to `nxt:` (single configured rclone remote → corporate Nextcloud at `cloud.victory62.org`, vendor `webdav/nextcloud`, user `victory`, рабочий каталог `nxt:Офис`).

**Always reference** `.claude/docs/nextcloud-cheatsheet.md` for paths, sensitivity matrix, save-routing matrix. Don't embed full content inline — read on demand.

## Three canonical workflows

### Workflow A — Upload artefact (PDF/photo/document to deal folder)

```
1. Determine target path through routing matrix:
   - Property.property_type.slug → subdir (КВАРТИРЫ/ДОМА/ЗЕМЛЯ/КОМНАТЫ/НЕЖИЛЫЕ...)
   - For КВАРТИРЫ/ЗЕМЛЯ → + GEO (РЯЗАНЬ/МОСКВА/САНКТ-ПЕТЕРБУРГ/прочие)
   - Deal-folder name = "<external_id> <ДЕЙСТВИЕ> <descriptor> <client_first_name>"

2. Check if deal folder exists:
   rclone lsd 'nxt:Офис/НЕДВИЖИМОСТЬ/КВАРТИРЫ/РЯЗАНЬ' | grep "<external_id>"

3a. If exists — backup-before-overwrite (если файл там тоже есть):
   rclone copyto 'nxt:.../...pdf' 'nxt:.../.archive/...-$(date +%Y%m%d-%H%M%S).pdf'

3b. If new folder — propose name to user, confirm перед mkdir:
   rclone mkdir 'nxt:Офис/НЕДВИЖИМОСТЬ/КВАРТИРЫ/РЯЗАНЬ/<proposed name>'

4. Upload:
   rclone copyto /local/file.pdf 'nxt:Офис/НЕДВИЖИМОСТЬ/.../file.pdf'

5. Verify:
   rclone lsl 'nxt:Офис/НЕДВИЖИМОСТЬ/.../file.pdf'
   # size + mtime sanity-check

6. (Optional) Share link → см. Workflow C
```

### Workflow B — Read template / reference for LLM context

```
1. Locate template in domain-tier (PREFER):
   rclone lsf 'nxt:Офис/НЕДВИЖИМОСТЬ/ОБРАЗЦЫ ДОКУМЕНТОВ' | grep -i 'договор\|дкп\|агентский'

2. Fetch to local temp:
   rclone copyto 'nxt:Офис/НЕДВИЖИМОСТЬ/ОБРАЗЦЫ ДОКУМЕНТОВ/АГЕНТСКИЙ ДОГОВОР март 2026.docx' /tmp/template.docx

3. Convert .docx → plain text для LLM context (docx2txt / pandoc / antiword):
   pandoc /tmp/template.docx -t plain -o /tmp/template.txt
   # OR: python3 -c "from docx import Document; print('\n'.join(p.text for p in Document('/tmp/template.docx').paragraphs))"

4. Feed text to LLM as system/context message
5. Generate output, save back через Workflow A (с user confirm на имя)
```

### Workflow C — Create share link для клиента (without rclone link)

`rclone link nxt:` НЕ работает (webdav backend Nextcloud не support). Альтернативы:

**Option 1 — OCS Share API (требует креды в env):**

```bash
# Encode path для URL:
PATH_ENC=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' '/Офис/НЕДВИЖИМОСТЬ/КВАРТИРЫ/РЯЗАНЬ/<deal>/dossier.pdf')

# Password for the share:
SHARE_PWD=$(openssl rand -base64 9)

# Create share:
curl -s -u "$NEXTCLOUD_USER:$NEXTCLOUD_PASS" \
     -H "OCS-APIRequest: true" \
     -d "path=$PATH_ENC" \
     -d "shareType=3" \
     -d "permissions=1" \
     -d "password=$SHARE_PWD" \
     -d "expireDate=$(date -d '+7 days' +%F)" \
     'https://cloud.victory62.org/ocs/v2.php/apps/files_sharing/api/v1/shares?format=json' \
  | python3 -m json.tool
# Response → data.url (public link); deliver URL + password separately to client
```

**Option 2 — Ask user to do it manually:**

```
1. Дай пользователю shortcut URL:
   https://cloud.victory62.org/index.php/apps/files/?dir=/Офис/НЕДВИЖИМОСТЬ/КВАРТИРЫ/РЯЗАНЬ/<deal>
2. User open → правый клик на file → Share → Create public link
3. User вставляет URL обратно в чат
4. Agent сохраняет URL в session inbox или передаёт через TG personal-bot
```

Default settings для public links (договариваемся всегда):
- **Password** — random 12-char (`openssl rand -base64 9`)
- **Expiration** — 7 дней
- **Permissions** — read-only (`permissions=1`)
- **Delivery** — URL + password через separate channels (URL в TG, password в SMS), не вместе

## Path / quoting gotchas

```bash
# ✅ Correct — single quotes preserve Cyrillic + spaces literally:
rclone lsd 'nxt:Офис/НЕДВИЖИМОСТЬ/КОТТЕДЖНОЕ  СТРОИТЕЛЬСТВО'

# ❌ Wrong — double quotes work but variable expansion happens:
rclone lsd "nxt:Офис/$VAR/..."   # only ОК if $VAR controlled

# ❌ Wrong — no quotes split on spaces:
rclone lsd nxt:Офис/НЕДВИЖИМОСТЬ/КОТТЕДЖНОЕ СТРОИТЕЛЬСТВО

# Path with double-space (real example in tree!):
'nxt:Офис/НЕДВИЖИМОСТЬ/КОТТЕДЖНОЕ  СТРОИТЕЛЬСТВО'   # ← 2 пробела между словами

# Normalise input from user: collapse runs of whitespace в single
# но при rclone access — match exactly как in remote
```

## Backup-before-overwrite (obligatory)

Если destination существует, **никогда** не перезаписывай напрямую:

```bash
DST='nxt:Офис/НЕДВИЖИМОСТЬ/КВАРТИРЫ/РЯЗАНЬ/<deal>/dossier.pdf'

# 1. Check existence
if rclone lsf "$DST" 2>/dev/null | grep -q .; then
  # 2. Backup
  TS=$(date +%Y%m%d-%H%M%S)
  rclone copyto "$DST" "${DST%/*}/.archive/$(basename "$DST" .pdf)-$TS.pdf"
fi

# 3. Write new
rclone copyto /local/new.pdf "$DST"

# 4. Verify
rclone lsl "$DST"
```

`.archive/` — convention subdir для versioning, hidden из normal listing.

## Verify after upload

```bash
# Single file:
rclone lsl 'nxt:Офис/НЕДВИЖИМОСТЬ/.../file.pdf'
# Expected: size + mtime > prior

# Folder sync:
rclone check /local/dir/ 'nxt:Офис/НЕДВИЖИМОСТЬ/.../'
# Output: "0 differences found" — OK

# Размер subtree (sanity-check для big uploads):
rclone size 'nxt:Офис/НЕДВИЖИМОСТЬ/<deal>/'
```

## Bandwidth discipline

Большие файлы (video .MOV, zip archives) — **warn user перед upload/download**:

```bash
# Limit upload speed (avoid saturating bandwidth):
rclone copyto /local/big.mov 'nxt:Офис/НЕДВИЖИМОСТЬ/<deal>/big.mov' --bwlimit 5M

# Parallel transfers (default 4) — для много мелких файлов:
rclone copy /local/dir 'nxt:Офис/...' --transfers 8 --checkers 16

# Progress:
rclone copyto ... --progress    # interactive
rclone copyto ... -v             # verbose for logs
```

Threshold для warning: > 100MB single file OR > 1GB total. Bring up в chat before executing.

## Common errors → fixes

| Error | Cause | Fix |
|---|---|---|
| `401 Unauthorized` | rclone config password expired / Nextcloud user disabled | Re-run rclone config + paste new password (user task) |
| `423 Locked` | Concurrent operation on same file (Nextcloud lock) | Wait 30s, retry. Don't bulk-overwrite while NC desktop sync active |
| `webdav doesn't support public links` | rclone link не работает на этом backend | Use OCS Share API (см. Workflow C) |
| Path mismatch (no such file) | Cyrillic encoding or stray space | Re-list parent dir: `rclone lsd 'nxt:<parent>'` → copy exact name |
| `409 Conflict` | mkdir на already-existing dir OR move с collision | Check first: `rclone lsd 'nxt:<parent>'` |
| Slow listing | Recursive on Уровень с тысячами файлов | Use `--max-depth N` + `--dirs-only` |
| Encoding warnings | Old NC files с Latin1 names | Не fixable client-side; user resolve в NC UI |

## Forbidden без explicit user OK

- `rclone delete`, `rclone purge`, `rclone deletefile` (любой path)
- `rclone move <X> <Y>` с overwrite Y (preserves nothing of old Y)
- Traversal of **sensitive-tier** dirs: БУХГАЛТЕРИЯ, БЕЗОПАСНОСТЬ, ПРИХОДЬКО О.В. РАЗНОЕ, КРЕДИТЫ
- **Любая операция в `Офис/Обмен`** — agent treats as non-existent (excluded)
- Bulk download > 100MB / upload > 100MB single file
- `rclone sync --delete` (destructive on destination — кроме explicit pre-staging scenarios)
- `rclone config` (config modification — user task)

## Deal-folder naming protocol

Когда нужно создать new deal folder:

1. **Gather data:** `Property.external_id`, `Property.deal_type`, `Property.title` (для descriptor), `Inquiry.client_name`
2. **Propose name** with template `<external_id> <ДЕЙСТВИЕ> <descriptor> <client_first>`:
   - Example proposed: `134567890 ПРОДАЖА 2-ка Канищево Светлана`
3. **Confirm с user** — у них может быть memorable name (e.g., `Slava Ostrov` vs proposed)
4. **mkdir** только после confirm:
   ```bash
   rclone mkdir 'nxt:Офис/НЕДВИЖИМОСТЬ/КВАРТИРЫ/РЯЗАНЬ/<confirmed name>'
   ```

## Snapshot refresh (deep-structure understanding)

При запросе «изучи Nextcloud»:

```bash
# 1. Domain tree (deep, dirs-only):
rclone lsf -R --dirs-only --max-depth 6 'nxt:Офис/НЕДВИЖИМОСТЬ' > /tmp/nextcloud-tree.txt

# 2. Categorise (regex):
# Active deals: '^.*/<digits>+ (ПРОДАЖА|АРЕНДА|ПОКУПКА|АНАЛИТИКА) '
# Archived deals: '^.*АРХИВ/<digit{4}>/<digits>+ ...'
# Funnel: '^.*/(ДУМАЮТ|ОТКАЗ|ПОД ЗАДАТКОМ)/'
# Audit reports: '^.*Отчёты по аудиту/<digit{4}-digit{2}-digit{2}> - '
# GEO: '^.*/(РЯЗАНЬ|МОСКВА|САНКТ-ПЕТЕРБУРГ|.../'

# 3. Counts per category:
awk -F'/' '/<digits>+ (ПРОДАЖА|АРЕНДА|ПОКУПКА)/ {count[$1"/"$2"/"$3]++} END {for (k in count) print k, count[k]}' /tmp/nextcloud-tree.txt

# 4. Persist:
mkdir -p .claude/agent-memory/nextcloud-rclone-ops
cat > .claude/agent-memory/nextcloud-rclone-ops/structure-snapshot.md <<EOF
# Nextcloud structure — snapshot $(date +%Y-%m-%d)
...
EOF
```

Auto-stale при mtime > 7 дней — agent предупреждает «snapshot outdated, refresh recommended».

## When to hand off

- **case-study-writer** wants to upload final PDF → that agent provides path + content, this skill ensures save discipline
- **client-onboarding-bot** uploads passport JSON → routes to `client-intake/` subdir (DLP)
- **pdf-telegram-dispatcher** distributes via TG → can use Nextcloud share link as inline attachment OR direct PDF
- **contract-drafter** (Phase D) needs template list → this skill reads from `НЕДВИЖИМОСТЬ/ОБРАЗЦЫ ДОКУМЕНТОВ`

## Anti-patterns

- ❌ Skip cheatsheet read (cargo-cult Cyrillic paths) → encoding errors
- ❌ Direct overwrite без backup → потеря старой версии
- ❌ Auto-move funnel folder (ДУМАЮТ → ПОД ЗАДАТКОМ) → user manually moves
- ❌ Use `rclone link` (не работает) → must use OCS API or manual UI
- ❌ Traverse sensitive-tier dirs ради curiosity → privacy violation
- ❌ Bulk download без bandwidth warning → user gets surprised by network saturation
- ❌ Index `Обмен` → it's excluded; treat as non-existent
- ❌ Use root `Шаблоны/` для contract templates → это generic Nextcloud (ODP/ODS), не real-estate
