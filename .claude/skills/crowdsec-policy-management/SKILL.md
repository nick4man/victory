---
name: crowdsec-policy-management
description: Use when managing CrowdSec on the production VDS — bouncer plugin params in Traefik middleware (mode/appsec/timeouts), `cscli decisions` (list/add/delete/whitelist), AppSec scenarios (config/scenarios/), acquisition tuning (acquis.yaml), profile decisions (ban/captcha/throttle), and metrics interpretation. Architecture is sidecar engine + Traefik plugin (confirmed via audit). Reference paths and current settings live in `.claude/docs/vds-infra-cheatsheet.md`. RELATED (.claude/docs/delegation-map.md) — pair with agent `traefik-vds-ops` для SSH execution; pair with skill `traefik-config-authoring` когда middleware bouncer-plugin изменяется (это touches Traefik dynamic config).
---

# CrowdSec policy management

CrowdSec на VDS — sidecar architecture: отдельный engine container `crowdsec`, parses Traefik access log через acquisition; Traefik подключён через bouncer-plugin `crowdsec-bouncer-traefik-plugin` v1.3.3. AppSec component включён (WAF rules).

**Reference paths cheatsheet:** `.claude/docs/vds-infra-cheatsheet.md` (lazy-read).

## Mental model

```
                ┌────────────────────┐
   Internet  ──▶│ Traefik (bouncer)  │──▶ backend (ok decision)
                │   plugin v1.3.3    │
                │                    │──▶ 403 block (bad IP from LAPI)
                │                    │──▶ 403 block (AppSec WAF triggered)
                └────────────────────┘
                       │
                       │ HTTP polling every 15s (stream mode)
                       │ /v1/decisions/stream
                       ▼
                ┌────────────────────┐
                │  CrowdSec engine   │
                │   LAPI :8080       │
                │   AppSec :7422     │
                │                    │
                │   SQLite DB        │
                │   acquisition      │◀── reads /var/log/traefik/access.log (mounted ro)
                │   scenarios        │
                │   bouncers list    │
                └────────────────────┘
```

Engine = brain. Bouncer (Traefik plugin) = enforcer. AppSec = WAF on hot-path (synchronous check).

## Commands cheatsheet

Always через SSH:

```bash
# === Health ===
ssh vds 'docker exec crowdsec cscli metrics | head -30'
ssh vds 'docker exec crowdsec cscli lapi status'
ssh vds 'docker exec crowdsec cscli bouncers list'      # ← Traefik plugin зарегистрирован?

# === Decisions (live bans) ===
ssh vds 'docker exec crowdsec cscli decisions list -o human | head -20'
ssh vds 'docker exec crowdsec cscli decisions list -o json | python3 -m json.tool'

# === Add manual decision ===
# Ban IP for 1 hour with reason:
ssh vds 'docker exec crowdsec cscli decisions add --ip 1.2.3.4 \
          --duration 1h --reason "manual block - abuse"'

# Ban CIDR range:
ssh vds 'docker exec crowdsec cscli decisions add --range 1.2.3.0/24 \
          --duration 24h --reason "scan attempt"'

# Captcha instead of ban (если scenario поддерживает):
ssh vds 'docker exec crowdsec cscli decisions add --ip 1.2.3.4 \
          --type captcha --duration 30m'

# === Remove decision ===
# Конкретный IP:
ssh vds 'docker exec crowdsec cscli decisions delete --ip 1.2.3.4'

# По decision-id:
ssh vds 'docker exec crowdsec cscli decisions delete --id 12345'

# ⚠️ ВСЕ decisions — DESTRUCTIVE, требует explicit user approve:
# ssh vds 'docker exec crowdsec cscli decisions delete --all'

# === Alerts (full history of triggered scenarios) ===
ssh vds 'docker exec crowdsec cscli alerts list | head -20'
ssh vds 'docker exec crowdsec cscli alerts inspect <alert-id>'

# === Scenarios installed ===
ssh vds 'docker exec crowdsec cscli scenarios list'

# === Parsers / postoverflows / collections ===
ssh vds 'docker exec crowdsec cscli parsers list'
ssh vds 'docker exec crowdsec cscli collections list'

# === Install new scenario from hub ===
ssh vds 'docker exec crowdsec cscli scenarios install crowdsecurity/http-bad-user-agent'
ssh vds 'docker exec crowdsec cscli hub upgrade'

# === Reload engine после config change ===
ssh vds 'docker exec crowdsec kill -HUP 1'   # SIGHUP — reload без restart
# или (heavier):
# ssh vds 'docker restart crowdsec'
```

## Bouncer plugin params (Traefik middleware)

Текущая конфигурация — в `/home/q/ubuntu_rep/traefik/config/config.yml`, middleware `crowdsec`. Tuning matrix:

| Param | Current | Trade-off |
|---|---|---|
| `crowdsecMode` | `stream` | **stream** — bouncer кэширует список banned client-side, polls LAPI каждые `updateIntervalSeconds`. Быстрый запрос, but ~30s stale-окно для новых banов. **live** — каждый запрос дёргает LAPI synchronously. Точнее, но latency удар. **alone** — без LAPI, локальный список. Не используется. |
| `updateIntervalSeconds` | `15` | Меньше → свежее decisions, больше LAPI нагрузка. 15s — sweet spot для prod. |
| `defaultDecisionSeconds` | `15` | Сколько action-decision действует когда LAPI вернул null. Не трогать. |
| `crowdsecAppsecEnabled` | `true` | WAF включён. Не выключай без хорошего повода (false-positives → tune scenarios). |
| `crowdsecAppsecFailureBlock` | `true` | AppSec returned ERR → block (strict). **Tradeoff: если AppSec падает → 100% traffic loss на defended routes.** |
| `crowdsecAppsecUnreachableBlock` | `true` | AppSec network unreachable → block. Same gotcha. |
| `forwardedHeadersTrustedIPs` | `10.0.0.0/8, 172.16.0.0/12` | Trust X-Forwarded-For ТОЛЬКО от этих сетей. Не добавляй public IP — это spoof-vector. Cloudflare IP-ranges — отдельная задача (cloudflarewarp plugin handles). |

После любого изменения bouncer-middleware — обязательно log-tail Traefik (`docker logs traefik --since 10s --tail 30`).

## Whitelist patterns

Три уровня whitelisting:

### 1. Manual single-IP decision (temporary)

```bash
# IP исключение на 24h — fastest:
ssh vds 'docker exec crowdsec cscli decisions add --ip <IP> \
          --duration 24h --reason "office IP" --type allow'
```

`--type allow` вместо `ban` — creates positive decision, overrides any ban. Expires автоматически.

### 2. Persistent acquisition whitelist

В `/home/q/ubuntu_rep/crowdsec/crowdsec+plugin/crowdsec/config/parsers/s02-enrich/whitelists.yaml`:

```yaml
name: crowdsecurity/whitelists
description: "Whitelist trusted IPs from triggering scenarios"
whitelist:
  reason: "office and partner IPs"
  ip:
    - "203.0.113.10"           # office
    - "198.51.100.0/24"        # partner network
  cidr:
    - "10.0.0.0/8"
    - "172.16.0.0/12"          # docker internal
```

После edit:
```bash
ssh vds 'docker exec crowdsec kill -HUP 1'   # reload
```

Reason: alerts от whitelisted IPs не создаются, decisions не добавляются. **Single source of truth** для permanent allowlist.

### 3. Per-scenario allowlist (advanced)

В конкретном scenario YAML:

```yaml
whitelist:
  reason: "Don't trigger 4xx-flood on health-check endpoints"
  expression:
    - 'evt.Parsed.target_path startsWith "/health"'
```

## AppSec — WAF tuning

AppSec работает inline (synchronous check). Custom rules: `/etc/crowdsec/appsec-rules/` внутри container, mapped из `/home/q/ubuntu_rep/crowdsec/crowdsec+plugin/crowdsec/config/`.

### Enable / disable rule set

```bash
ssh vds 'docker exec crowdsec cscli appsec-configs list'
ssh vds 'docker exec crowdsec cscli appsec-rules list'

# Install official rule set (crowdsecurity/appsec-virtual-patching covers OWASP top):
ssh vds 'docker exec crowdsec cscli appsec-configs install crowdsecurity/virtual-patching'
```

### Test rule before enable

CrowdSec — test mode для каждого правила. Sequence:
1. Add rule to config с `mode: test` (alert-only, не блокирует)
2. Reload engine
3. Через 24-48h — посмотри `cscli alerts list | grep appsec` — много false positives?
4. Если чисто — switch к `mode: block`

### Common AppSec gotchas

- **Multipart upload triggers POST scanning** — uploads большие файлы могут fail AppSec timeout. Whitelist upload paths if needed.
- **WebSocket upgrades** — AppSec doesn't WS, just initial handshake. Не блокирует WS-traffic.
- **GraphQL requests** — single-endpoint POST с complex bodies. Может trigger generic rules; tune отдельно.

## Acquisition tuning (acquis.yaml)

Current acquisition reads `/var/log/traefik/access.log`. Чтобы добавить новый log source (e.g., Nginx behind Traefik):

```yaml
# acquis.yaml (новый блок ниже existing):
---
filenames:
  - /var/log/nginx/access.log
labels:
  type: nginx
```

Затем — install parser для типа:
```bash
ssh vds 'docker exec crowdsec cscli parsers install crowdsecurity/nginx-logs'
ssh vds 'docker exec crowdsec kill -HUP 1'
```

**Critical**: log file должен быть mounted в crowdsec container (`docker inspect crowdsec | grep -A3 Mounts`). Если нет — отдельная задача adjust container mounts (требует `docker compose up -d crowdsec` rebuild).

## Profile decisions (ban vs captcha vs throttle)

`profiles.yaml` — что делать при alert. Default:

```yaml
name: default_ip_remediation
filters:
  - Alert.Remediation == true && Alert.GetScope() == "Ip"
decisions:
  - type: ban
    duration: 4h
```

Custom example — captcha для middle-severity, ban для high:

```yaml
name: graduated_remediation
filters:
  - Alert.Remediation == true && Alert.GetScope() == "Ip" && Alert.GetScenario() contains "http-probing"
decisions:
  - type: captcha            # ← если scenario поддерживает (нужен captcha provider)
    duration: 30m
---
name: severe_ban
filters:
  - Alert.Remediation == true && Alert.GetScope() == "Ip" && Alert.GetScenario() contains "http-cve"
decisions:
  - type: ban
    duration: 24h
```

После edit — reload SIGHUP.

## Metrics interpretation

```bash
ssh vds 'docker exec crowdsec cscli metrics'
```

Output sections:
- **Acquisition**: reads (входящий лог поток), drops (no parser matched), parsed
- **Buckets**: scenarios fired, count of overflows
- **Parsers**: per-parser hit count
- **Bouncer (Traefik)**: requests served, decisions cached
- **AppSec**: tests, blocks, false-positive

**Health indicators:**
- `drops` > 50% от reads → парсер не подходит, нужен другой
- `parsed` росьет, но `buckets` пустой → событий нет (норма для тихого periода)
- Bouncer `failures` > 0 → connectivity issue Traefik ↔ CrowdSec

## Anti-patterns

- ❌ `cscli decisions delete --all` без approve — массовый разбан, теряются auto-rules
- ❌ Whitelist через manual decision вместо acquisition whitelist — persistent allowlist должен быть в config
- ❌ AppSec rule в `block` mode без 24-48h `test` mode — high false-positive risk на product traffic
- ❌ Disable `crowdsecAppsecUnreachableBlock` — без него если AppSec crash → permissions wide open
- ❌ Trust X-Forwarded-For от public IP в `forwardedHeadersTrustedIPs` — spoof vector
- ❌ Не reload через SIGHUP после config change → конфиг живёт в файле, но engine использует старый

## When to hand off

- 🔄 Plugin upgrade `crowdsec-bouncer-traefik-plugin` v1.3.3 → vNext — отдельный subplan, нужен Traefik restart (см. `traefik-config-authoring` plugin upgrade workflow)
- 🆕 Custom scenario написать с нуля — отдельный sprint subplan, нужны access logs для training
- 📊 Dashboard / Metabase integration — отдельный subplan
- ⚙️ Изменения в Traefik middleware-config (когда middleware bouncer params меняются) — координация со skill `traefik-config-authoring`

## Recovery — что делать когда сайт лёг

Quick diagnostics (порядок важен):

```bash
# 1. CrowdSec жив?
ssh vds 'docker ps --filter "name=crowdsec" --format "{{.Status}}"'

# 2. AppSec reachable?
ssh vds 'docker exec traefik wget -qO- http://crowdsec:7422/ 2>&1 | head -3'

# 3. LAPI reachable?
ssh vds 'docker exec traefik wget -qO- http://crowdsec:8080/v1/heartbeat 2>&1'

# 4. Если AppSec/LAPI down — пользователи блочатся через crowdsecAppsecUnreachableBlock:
#    Emergency disable bouncer middleware на critical route (commit + log-tail).
#    Followup — поднять CrowdSec.
```

Emergency disable bouncer middleware на route — закомментировать `- crowdsec` в route's middleware chain (как уже сделано для `victory62.org` — это и был, вероятно, такой случай). Не permanent fix — выясни почему AppSec/LAPI down.
