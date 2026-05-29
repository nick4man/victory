# Nextcloud (rclone) cheatsheet — `nxt:`

> Single source of truth о корпоративном Nextcloud на `cloud.victory62.org`, доступном локально через `rclone` remote `nxt`. Обновляй вручную при изменениях в структуре или через agent `nextcloud-rclone-ops` после approve.

## Remote identity

| Aspect | Value |
|---|---|
| Remote name | `nxt:` |
| Backend type | `webdav` (vendor `nextcloud`) |
| URL | `https://cloud.victory62.org/remote.php/dav/files/victory` |
| Nextcloud user | `victory` |
| Local binary | `/usr/bin/rclone` v1.74.1 |
| Quota | Used 58.053 MiB (Nextcloud admin не выставил total/free — `rclone about nxt:` возвращает только Used) |

## Critical limitations (discovered)

- **`rclone link nxt:<path>` НЕ работает** — WebDAV backend Nextcloud не support public links через rclone (`doesn't support public links`).
  - **Альтернатива 1:** Nextcloud OCS Share API через `curl` (см. § Share links ниже)
  - **Альтернатива 2:** User вручную через Nextcloud UI (правый клик → Share → copy link)
- **Cyrillic paths** — обязательны single-quote literal в Bash: `'nxt:Офис/НЕДВИЖИМОСТЬ/...'` без quote шелл сломает.
- **`Шаблоны/` (root)** — это **Nextcloud generic** templates (ODT/ODS/ODP, Brainstorming.whiteboard, etc.). Полезно для офисной работы, **НЕ для contract-drafter** — там `НЕДВИЖИМОСТЬ/ОБРАЗЦЫ ДОКУМЕНТОВ/`.

## Root structure

```
nxt:Documents                   # Nextcloud default — readme/welcome
nxt:Photos                      # Nextcloud default — sample album
nxt:Сканы                       # сканированные документы (с 2026-01)
nxt:Шаблоны                     # Nextcloud generic templates (ODT/ODS/ODP)
nxt:Офис                        # ← РАБОЧИЙ КАТАЛОГ
```

## `Офис/` subtree (15 subdirs)

| Subdir | Tier | Relevance |
|---|---|---|
| `3 НДФЛ` | reference | tax docs |
| `feeds` | low | legacy |
| `АРХИВ` | reference | старые artefacts |
| **`БАНКИ`** | **reference (read-heavy)** | банковские программы (17+ банков: АБСОЛЮТ, АГРОРОС, АЛЬФА, ВТБ ПАО, Газпромбанк, Открытие, ...) — **источник для chatbot RAG + mortgage calculator** |
| `БЕЗОПАСНОСТЬ` | sensitive | — |
| `БУХГАЛТЕРИЯ` | sensitive | — |
| `КРЕДИТЫ` | sensitive | — |
| **`НЕДВИЖИМОСТЬ`** | **domain-work** | главная domain работа (подробно ниже) |
| **`ОБРАЗЦЫ ДОКУМЕНТОВ`** | reference (read-heavy) | top-level generic templates (fallback для contract-drafter) |
| `ОБУЧЕНИЕ` | low | training |
| `ООО ЦДПО ЭКСПЕРТ` | reference | legal entity docs |
| **`Обмен` (`ОБМЕН`)** | **EXCLUDED** | human-only staging — agent treats as **non-existent** |
| `ПИСЬМА` | low | letters |
| `ПРИХОДЬКО О.В. РАЗНОЕ` | sensitive | — |
| **`ПРОЕКТЫ`** | domain-work | проекты (deal-supporting material) |

## Sensitivity matrix

| Tier | Dirs | Agent access |
|---|---|---|
| **Public-ish** | Documents, Photos, Шаблоны | Free read+write |
| **Domain-work** | Офис/НЕДВИЖИМОСТЬ, Офис/ПРОЕКТЫ, Офис/АРХИВ | Free read+write (backup-before-overwrite) |
| **Reference (read-heavy)** | Офис/БАНКИ, Офис/ОБРАЗЦЫ ДОКУМЕНТОВ, Сканы, НЕДВИЖИМОСТЬ/ОБРАЗЦЫ ДОКУМЕНТОВ, НЕДВИЖИМОСТЬ/Отчёты по аудиту | Read-only по умолчанию; write only с explicit user OK |
| **Sensitive** | Офис/БУХГАЛТЕРИЯ, Офис/БЕЗОПАСНОСТЬ, Офис/ПРИХОДЬКО О.В. РАЗНОЕ, Офис/КРЕДИТЫ | **No agent traversal** |
| **Excluded** | **Офис/Обмен** (aka ОБМЕН) | **Skip indexing entirely** — treat as non-existent |

## `НЕДВИЖИМОСТЬ/` (полный subtree)

```
АРЕНДА/                          активные сделки аренды + АРХИВ
АРХИВ/                           по годам 2018-2026 + ДУМАЮТ о ПРОДАЖЕ + ОТКАЗНИКИ
БЕЗОПАСНОСТЬ/                    ПРОВЕРКИ/ (sensitive)
ГАРАЖИ/                          deal-folders + Новая папка + документы на объект
ДОМА/                            deal-folders + АРХИВ
ЗАРУБЕЖНАЯ НЕДВИЖИМОСТЬ/         ГЕРМАНИЯ, ГРУЗИЯ, ОАЭ, СЕВЕРНЫЙ КИПР, ТУРЦИЯ
ЗАСТРОЙЩИКИ и АН/                по гео + brand (Брусника, Самолет Плюс, ТрендАгент, ...)
ЗЕМЛЯ/                           АРХИВ, КАЛУЖСКАЯ ОБЛАСТЬ, КРАСНОДАРСКИЙ КРАЙ, МОСКОВСКАЯ ОБЛАСТЬ, РЯЗАНСКАЯ ОБЛАСТЬ, РЯЗАНЬ
КВАРТИРЫ/                        по гео + funnel-статусы (см. ниже)
КОМНАТЫ/                         deal-folders + АРХИВ
КОТТЕДЖНОЕ  СТРОИТЕЛЬСТВО/       (двойной пробел!) Ипотека ВТБ/СБЕР + ЖК + презентации
Квартиры проф.сьемка/            хоумстейджинг + проф-фото reference
МАРКЕТ-ПЛЭЙСЫ-АГРЕГАТОРЫ-СРМ/    TopNlab + ЦИАН + АГРЕГАТОРЫ
НЕЖИЛЫЕ ЗДАНИЯ- ПОМЕЩЕНИЯ/       commerce deals
ОБРАЗЦЫ ДОКУМЕНТОВ/              domain-specific templates (ДКП, аккредитив, агентский, ...)
Отчёты по аудиту/                YYYY-MM-DD - <theme>/  (15+ benchmark reports)
ПОКУПКА/                         когда мы помогаем КЛИЕНТУ покупать
РЕКЛАМА на САЙт и в соц.сети/    marketing artefacts
СОЦИАЛЬНЫЕ ВЫПЛАТЫ/              маткап, военка, etc.
ТОРГИ/                           аукционы
```

### КВАРТИРЫ subtree

```
АРХАНГЕЛЬСК, ВЛАДИМИР, ГРУЗИЯ, ЛИПЕЦК, МОСКВА, МОСКОВСКАЯ ОБЛАСТЬ,
Мурманск, РЯЗАНСКАЯ ОБЛАСТЬ, РЯЗАНЬ, САНКТ-ПЕТЕРБУРГ           — гео
ДУМАЮТ/                          — funnel: buyer considering
ОТКАЗ/                           — funnel: rejected
ПОД ЗАДАТКОМ/                    — funnel: in escrow
Варианты отделки квартир/        — reference: interior samples
Квартиры проф.сьемка/            — reference: professional shoots
НОВОСТРОЙКИ СТРОЙПРОМСЕРВИС/     — brand новостроек
```

### Property-type ↔ subdir mapping

```
Property.property_type.slug    → НЕДВИЖИМОСТЬ subdir
flat                           → КВАРТИРЫ/<GEO>/
house                          → ДОМА/
land                           → ЗЕМЛЯ/<GEO>/
room                           → КОМНАТЫ/
commerce                       → НЕЖИЛЫЕ ЗДАНИЯ- ПОМЕЩЕНИЯ/
(cottage if exists)            → КОТТЕДЖНОЕ  СТРОИТЕЛЬСТВО/
foreign (any country flag)     → ЗАРУБЕЖНАЯ НЕДВИЖИМОСТЬ/<COUNTRY>/
```

### GEO sub-subdir для КВАРТИРЫ + ЗЕМЛЯ

```
Address contains "Рязань" or city == Рязань     → РЯЗАНЬ/
Address contains "Москва"                        → МОСКВА/
Address contains "Санкт-Петербург" или СПб       → САНКТ-ПЕТЕРБУРГ/
Other RF cities                                  → top-level city name (если subdir уже существует)
                                                   иначе предложить mkdir
```

### Deal-folder naming convention

```
<TopNlab-ID> <ДЕЙСТВИЕ> <Краткий-descriptor> <ClientFirstName>
```

**Examples (real, из НЕДВИЖИМОСТЬ):**
- `128248561 ПРОДАЖА 2-ка Сенная 18-21 Вика`
- `109962925 ПРОДАЖА Дом Рыбновский р-н Влад`
- `91613560 ПРОДАЖА 3-комн Черновицкая 4-2-11 Лена Максик`
- `128998950 АРЕНДА Касимовское шоссе 67 Зотов Дмитрий`
- `107389055 ПРОДАЖА Куйб шоссе стоянка на М5`

**Parts:**
| Part | Source | Notes |
|---|---|---|
| `TopNlab-ID` | `Property.external_id` | numeric, обязательный prefix |
| `ДЕЙСТВИЕ` | `Property.deal_type` enum mapped: `sale → ПРОДАЖА`, `rent → АРЕНДА`; buying-side — `ПОКУПКА` | RU uppercase |
| `descriptor` | natural-language: `1-ка/2-ка/3-ка` для квартир; `Дом/Усадьба/Дача/Таунхаус` для домов; address — необязательно но полезно | agent **предлагает**, user confirms |
| `ClientFirstName` | `Inquiry.client_name.split.first` | полное имя если short (Вика, Влад, Андрей Викторович) |

Agent НИКОГДА не делает `mkdir` без user confirmation на name.

### Deal-folder internals — FLAT

Внутри `109548585 ПРОДАЖА Усадьба Андрей Викторович/` файлы лежат **напрямую** (IMG_3020.jpg ... IMG_3374.jpg). **НЕТ** subdirs `photos/`, `contracts/`, `audit/`. Agent НЕ создаёт structure если user её не использует.

**Exception:** `client-intake/` subdir для DLP isolation OCR'енных passport/ИНН/выписок — sensitive client data отделяем.

### Audit reports — отдельная convention

```
Отчёты по аудиту/
  YYYY-MM-DD - <theme>/

Examples:
  2026-04-13 - ЖК 1-й Донской
  2026-04-14 - Аудит 10 городов (Детальный)
  2026-04-15 - Benchmark Москва
  2026-04-25 - Стратегия релокации Рязань-Москва
```

**Per-property audits** идут в deal folder (`<deal>/audit-YYYY-MM-DD.pdf`). **Macro/рыночные audits** — в `Отчёты по аудиту/`.

### Templates — two-tier с фактическим content

| Tier | Path | Content (real) | Use case |
|---|---|---|---|
| **Domain — PREFER** | `Офис/НЕДВИЖИМОСТЬ/ОБРАЗЦЫ ДОКУМЕНТОВ/` | АГЕНТСКИЙ ДОГОВОР март 2026.docx, ДКП-аккредитив.doc, ДКП Мкртчян.docx, ДКБ с вариативностью.docx, ВТБ-2020-ДКП_МО.DOC, соглашение наделения детей долями, ходатайство о переносе судебн.заседания, Аренда/, Банковские гарантии/ | contract-drafter (Phase D), realtor work |
| Fallback | `Офис/ОБРАЗЦЫ ДОКУМЕНТОВ/` | (содержание не разведано — placeholder) | если в domain-tier нет нужного |
| **NOT domain** | `Шаблоны/` (root) | Generic Nextcloud (Brainstorming, Business model canvas, Calendar, Flowchart, ...) | **НЕ используем** для real-estate |

### Funnel-статусы как папки

```
КВАРТИРЫ/ДУМАЮТ/                    buyer considering
КВАРТИРЫ/ОТКАЗ/                     rejected
КВАРТИРЫ/ПОД ЗАДАТКОМ/              in escrow
АРХИВ/ДУМАЮТ о ПРОДАЖЕ/             sellers thinking
АРХИВ/ОТКАЗНИКИ/                    seller-side rejected
АРХИВ/<YEAR>/                       closed deals by year (2018-2026)
```

Agent: **read-only** для status detection (вернуть «вот 5 deals в ПОД ЗАДАТКОМ»). **Не двигает** папки между статусами автоматом — user manually moves.

## Save-routing matrix (canonical)

| Artefact | Target path (relative to `nxt:Офис/НЕДВИЖИМОСТЬ/`) | Notes |
|---|---|---|
| Property photos | `<Type>/<deal-folder>/IMG_*.jpg` | FLAT, без `photos/` subdir |
| Property dossier PDF (private, premium) | `<Type>/<deal-folder>/<filename>.pdf` | flat |
| Generated договор draft | `<Type>/<deal-folder>/<filename>.docx` | flat |
| Per-property audit report | `<Type>/<deal-folder>/audit-YYYY-MM-DD.pdf` | flat |
| Macro/market audit | `Отчёты по аудиту/YYYY-MM-DD - <theme>/` | separate convention |
| Video (deal-specific) | `<Type>/<deal-folder>/<filename>.MOV` | flat (bandwidth warning) |
| Professional photo shoot | `Квартиры проф.сьемка/<address>/` | reference, не per-deal |
| Case-study PDF (anonymised, post-close) | `<Type>/АРХИВ/<YEAR>/<deal-folder>/case-study.pdf` | после move в архив user'ом |
| OCR'd client docs (sensitive) | `<Type>/<deal-folder>/client-intake/<doc>-YYYYMMDD.json` | **subdir** — DLP isolation |
| Bank programs reference (READ) | ← `Офис/БАНКИ/<bank>/` | НЕ пишем |
| ↳ cottage-specific bank ipoteka | ← `НЕДВИЖИМОСТЬ/КОТТЕДЖНОЕ  СТРОИТЕЛЬСТВО/Ипотека ВТБ\|СБЕР/` | read-only |
| Contract template (READ) — PREFER | ← `НЕДВИЖИМОСТЬ/ОБРАЗЦЫ ДОКУМЕНТОВ/` | domain |
| ↳ fallback templates | ← `Офис/ОБРАЗЦЫ ДОКУМЕНТОВ/` | generic real-estate |
| Foreign-investor deal (Phase B) | `ЗАРУБЕЖНАЯ НЕДВИЖИМОСТЬ/<COUNTRY>/<deal-folder>/` | по странам |
| Developer/agency contact | `ЗАСТРОЙЩИКИ и АН/<GEO>/<Brand>/` | reference |
| Marketing / SMM artefact | `РЕКЛАМА на САЙт и в соц.сети/` | контент-команда |

## Share links — workflow (без `rclone link`)

`rclone link nxt:` **НЕ работает** на этом remote. Альтернативы:

### Option 1 — Nextcloud OCS Share API через curl

Требует `NEXTCLOUD_USER` + `NEXTCLOUD_PASS` (или app-token) в env. **НЕ store credentials в repo — только env-vars.**

```bash
# Создать public link share с password + 7-day expiration
ENCODED_PATH=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' '/Офис/НЕДВИЖИМОСТЬ/КВАРТИРЫ/РЯЗАНЬ/<deal>/dossier.pdf')

curl -s -u "$NEXTCLOUD_USER:$NEXTCLOUD_PASS" \
     -H "OCS-APIRequest: true" \
     -d "path=$ENCODED_PATH" \
     -d "shareType=3" \
     -d "permissions=1" \
     -d "password=$(openssl rand -base64 9)" \
     -d "expireDate=$(date -d '+7 days' +%F)" \
     'https://cloud.victory62.org/ocs/v2.php/apps/files_sharing/api/v1/shares?format=json' \
  | python3 -m json.tool
```

Response содержит `data.url` (public link) + `data.token`. Сохранить URL+password в session inbox или TG personal-bot.

### Option 2 — User вручную через Nextcloud UI

Open `https://cloud.victory62.org/index.php/apps/files/?dir=/Офис/<path>` → правый клик на file → Share → Create public link → copy URL.

Agent даёт shortcut URL + инструкцию, user возвращает share link.

## Backup naming pattern (overwrite-safe)

```bash
# Перед overwrite existing destination — сохранить старую версию:
rclone copyto nxt:Офис/НЕДВИЖИМОСТЬ/<deal>/dossier.pdf \
              nxt:Офис/НЕДВИЖИМОСТЬ/<deal>/.archive/dossier-$(date +%Y%m%d-%H%M%S).pdf

# Затем upload new version:
rclone copyto /local/new-dossier.pdf nxt:Офис/НЕДВИЖИМОСТЬ/<deal>/dossier.pdf
```

`.archive/` — конвенциональный subdir для versioning внутри deal folder; hidden из обычного browsing.

## Common rclone commands (Nextcloud-specific)

```bash
# Listing
rclone listremotes                                            # → nxt:
rclone lsd 'nxt:Офис'                                         # subdirs
rclone lsf 'nxt:Офис/НЕДВИЖИМОСТЬ/КВАРТИРЫ/РЯЗАНЬ'             # files+dirs flat
rclone lsf -R --dirs-only --max-depth 4 'nxt:Офис/НЕДВИЖИМОСТЬ'  # recursive tree
rclone lsl 'nxt:Офис/НЕДВИЖИМОСТЬ/<deal>/'                    # detailed (size + mtime)

# Read content
rclone cat 'nxt:Офис/НЕДВИЖИМОСТЬ/ОБРАЗЦЫ ДОКУМЕНТОВ/ДКП.docx'  # NB: docx binary — pipeline через text extractor
rclone copyto 'nxt:Офис/<file>' /tmp/local-copy                # safer pull для inspect

# Write (с backup-before-overwrite!)
rclone copyto /local/file.pdf 'nxt:Офис/НЕДВИЖИМОСТЬ/<deal>/file.pdf'
rclone copy   /local/dir/    'nxt:Офис/НЕДВИЖИМОСТЬ/<deal>/'   # directory upload
rclone mkdir 'nxt:Офис/НЕДВИЖИМОСТЬ/<NEW deal-folder>'         # требует user confirm на name

# Verify
rclone check /local 'nxt:Офис/<remote>'                       # diff local vs remote
rclone size 'nxt:Офис/НЕДВИЖИМОСТЬ'                           # bytes total

# About / health
rclone about nxt:                                             # used / quota
```

## Forbidden без explicit user OK

- `rclone delete`, `rclone purge`, `rclone deletefile` (любой path)
- `rclone move` который overwrite destination
- Traversal of **sensitive-tier** dirs (БУХГАЛТЕРИЯ, БЕЗОПАСНОСТЬ, ПРИХОДЬКО О.В. РАЗНОЕ, КРЕДИТЫ)
- **Любая операция в `Офис/Обмен`** (excluded tier)
- Bulk download > 100MB (bandwidth + token cost)
- `rclone sync --delete` (destructive on dst)
- `rclone config` (config modification)

## Hand-off destinations (agent-coordination)

| Other agent | Reads from Nextcloud | Writes to Nextcloud |
|---|---|---|
| `case-study-writer` | `НЕДВИЖИМОСТЬ/<Type>/<deal>/` (photos + audit + intake) для context | `<Type>/АРХИВ/<YEAR>/<deal>/case-study.pdf` (после close) |
| `client-onboarding-bot` | — | `<Type>/<deal>/client-intake/passport-YYYYMMDD.json` (DLP-isolated subdir) |
| `pdf-report-designer` + `pdf-telegram-dispatcher` | template из `ОБРАЗЦЫ ДОКУМЕНТОВ` | dossier/audit PDF в `<Type>/<deal>/` |
| `property-valuation-expert` | comparable analogs context (если стояли в `БАНКИ/ОЦЕНКА` или audit reports) | per-property audit в `<Type>/<deal>/audit-YYYY-MM-DD.pdf` |
| `market-analytics-publisher` | `Отчёты по аудиту/` macro reports как context | macro audit `Отчёты по аудиту/YYYY-MM-DD - <theme>/` |
| Future `contract-drafter` (Phase D) | `НЕДВИЖИМОСТЬ/ОБРАЗЦЫ ДОКУМЕНТОВ/` templates + client data | `<Type>/<deal>/<contract-type>-draft-YYYY-MM-DD.docx` |

## Snapshot file (agent-memory)

Agent persists discovered structure в `.claude/agent-memory/nextcloud-rclone-ops/structure-snapshot.md` (gitignored). Contents:
- Last refresh timestamp
- Counts: `(PropertyType, GEO, active deals, archived)` × all combinations
- Audit reports list (date + theme)
- Funnel status counts
- Template files inventory in ОБРАЗЦЫ ДОКУМЕНТОВ

Refresh: manual via «изучи Nextcloud» OR auto-stale при mtime > 7 дней.

## Known issues / TODO

- ⚠️ `rclone link` не работает → нужна OCS Share API integration. Pending: NEXTCLOUD_USER/PASS в env (или app-token).
- ⚠️ `.DS_Store`, `Thumbs.db` накапливаются (macOS/Windows noise) — cleanup mini-task.
- ⚠️ `Новая папка` в нескольких местах (ГАРАЖИ, ЗАСТРОЙЩИКИ и АН, КОТТЕДЖНОЕ СТРОИТЕЛЬСТВО) — Russian Windows default — cleanup candidate.
- ⚠️ Двойной пробел в имени `КОТТЕДЖНОЕ  СТРОИТЕЛЬСТВО` (есть и одиночный variant) — может вызвать issues при path-matching. Agent должен normalise input.
- Quota / total space — Nextcloud admin не выставил, `rclone about` неполный — игнорируем пока storage не пухнет.

## Related agent / skill

- Agent **`nextcloud-rclone-ops`** — entry point для всех Nextcloud-операций
- Skill **`rclone-nextcloud-patterns`** — commands cheatsheet + safety + share-link workflow
- VDS-сторона Nextcloud (server admin) — см. `.claude/docs/vds-infra-cheatsheet.md` (router `nextcloud` для `cloud.victory62.org`)
