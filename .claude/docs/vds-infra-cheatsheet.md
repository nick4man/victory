# VDS infra cheatsheet — Traefik + CrowdSec

> Single source of truth о production VDS, на котором живёт `victory62.org` (+ adjacent services). Discovered via read-only audit; обновляй при изменениях вручную или через agent `traefik-vds-ops` после approve.

## Host identity

| Aspect | Value |
|---|---|
| SSH alias | `vds` |
| HostName | `sodix.org` |
| User | `q` (same UID as local dev — same Git identity) |
| OS | Ubuntu 24.04, kernel 6.11 |
| Engine | Docker (compose-based; sudo not needed for `docker ps`) |

## Containers

| Name | Image | Role | Network IP |
|---|---|---|---|
| `traefik` | `traefik:latest` | Edge reverse-proxy (HTTPS termination, routing) | proxy/172.18.0.2 |
| `crowdsec` | `crowdsecurity/crowdsec:latest` | LAPI engine + AppSec (WAF) sidecar | proxy/172.18.0.3 |
| (other) | various | Backends accessed via traefik docker labels | proxy/* |

Docker network: **`proxy`** (bridge, 172.18.0.0/16). Все routed-сервисы должны быть в нём же — `docker network connect proxy <container>` если новый сервис вне compose.

## Paths

### Traefik (mounted volumes)

```
Static config (mounted ro → /traefik.yaml):
  /home/q/ubuntu_rep/traefik/data/traefik.yaml

Dynamic config (mounted ro → /config, watch: true):
  /home/q/ubuntu_rep/traefik/config/
    config.yml                         главный — routers + services + crowdsec middleware
    authentik.yaml                     SSO integration (forwardAuth)
    basic-auth.yml                     basicAuth middleware (htpasswd-style users)
    https-redirect.yaml                redirect helper middleware
    middlewares-buffering.yaml         buffering tuning
    rate-limit.yaml                    rate limit middleware
    security-headers.yaml              HSTS / X-Content-Type-Options / X-Frame-Options / Referrer-Policy / STS
    AllowListTCP.yml                   IP allow-list для TCP routers
    tcp-rdp.yml                        RDP TCP route
    nextcloud/nextcloud-chain.yaml     per-app middleware chain
    pihole/                            DNS UI configs

Logs (mounted rw → /var/log/traefik):
  /home/q/ubuntu_rep/traefik/logs/
    access.log                         access log (used by CrowdSec acquisition)
    traefik-err.log                    error log — tail после edit'а для verification

ACME (mounted rw → /acme.json):
  /home/q/ubuntu_rep/traefik/data/acme.json
  # 600 perms! НЕ читать через шумные команды (logs); only when troubleshooting cert.
```

### CrowdSec (mounted volumes)

```
Acquisition (mounted rw → /etc/crowdsec/acquis.yaml):
  /home/q/ubuntu_rep/crowdsec/crowdsec+plugin/crowdsec/acquis.yaml
  # log_sources, labels, parsers; добавление нового источника = add block + restart engine

Engine config (mounted rw → /etc/crowdsec):
  /home/q/ubuntu_rep/crowdsec/crowdsec+plugin/crowdsec/config/
    config.yaml                  главный
    scenarios/                   detection scenarios
    profiles.yaml                decision profiles (что делать с alert: ban / captcha)
    notifications/               outputs

Database (mounted rw → /var/lib/crowdsec/data):
  /home/q/ubuntu_rep/crowdsec/crowdsec+plugin/crowdsec/db/
  # SQLite по умолчанию; back-up обязателен перед manual edit

Traefik logs (mounted ro → /var/log/traefik):
  /home/q/ubuntu_rep/traefik/logs/
  # CrowdSec парсит access.log через acquisition
```

## Traefik static config (`traefik.yaml`) highlights

```yaml
api:
  dashboard: true                # доступ через port 8080 (через router)
entryPoints:
  web: address: ":80"            # HTTP → 301 → websecure
  websecure: address: ":443"     # HTTP/3 ВЫКЛЮЧЕН (troubleshoot instability)
  metrics: address: ":8082"      # Prometheus scrape
providers:
  docker:                        # auto-discover via labels
    exposedByDefault: false      # ← важно: только сервисы с traefik.enable=true
  file:
    directory: /config
    watch: true                  # hot-reload, watch dir
certificatesResolvers:
  cloudflare:                    # DNS-01 — для wildcard, нужен CLOUDFLARE_DNS_API_TOKEN env
    acme:
      email: acom@nxt.ru
      storage: /acme.json
  letsencrypt:                   # HTTP-01 — для одиночных доменов
    acme:
      email: oks07@yandex.ru
      storage: /letsencrypt/acme.json
serversTransport:
  insecureSkipVerify: true       # ← backends с self-signed позади Traefik OK
log:
  level: "ERROR"                 # tail /var/log/traefik/traefik-err.log при verification
experimental:
  plugins:
    cloudflarewarp:                          v1.3.3
    crowdsec-bouncer:                        v1.3.3 (module: github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin)
```

**Critical**: static config edit ≠ hot-reload. Требует **`docker restart traefik`** — production-impact (~3-5s downtime). НЕ trogati без явного approve.

## CrowdSec bouncer middleware (defined in `config.yml`)

```yaml
http:
  middlewares:
    crowdsec:
      plugin:
        crowdsec-bouncer:
          enabled: true
          logLevel: INFO
          updateIntervalSeconds: 15            # как часто bouncer тянет decisions
          updateMaxFailure: 0
          defaultDecisionSeconds: 15
          httpTimeoutSeconds: 10
          crowdsecMode: stream                 # ← cache decisions client-side
          crowdsecAppsecEnabled: true          # ← WAF включён
          crowdsecAppsecHost: crowdsec:7422    # internal docker DNS
          crowdsecAppsecFailureBlock: true     # ← FAIL → block (strict)
          crowdsecAppsecUnreachableBlock: true # ← если AppSec down → block
          crowdsecLapiKey: <LAPI_KEY>          # в plaintext (acceptable behind firewall)
          crowdsecLapiHost: crowdsec:8080      # internal docker DNS
          crowdsecLapiScheme: http
          forwardedHeadersTrustedIPs:
            - 10.0.0.0/8
            - 172.16.0.0/12                    # ← trust Docker internal proxies
```

## Existing routers (production snapshot)

| Router name | Host rule | Middlewares chain | Service | Notes |
|---|---|---|---|---|
| `dev-canvas` | `dev.victory62.org` | securityHeaders, gzip | service-dev-canvas | TLS cloudflare DNS-01 |
| `dev-wildcard` | `{subdomain:[a-z0-9-]+}.dev.victory62.org` | securityHeaders, gzip | service-dev-canvas | wildcard cert |
| `openclaw` | `gateway.victory62.org` | securityHeaders, https-redirect | service-openclaw | |
| `nextcloud` | `cloud.victory62.org` | **crowdsec**, nextcloud-chain, gzip | nextcloud | |
| `nextcloud-push` | `cloud.victory62.org` (sub-path) | push-stripprefix | nextcloud-push | |
| `collabora` | `office.victory62.org` | websocketHeaders, securityHeaders | collabora | document edit |
| `victory` | `victory62.org` | default-headers, https-redirect | victory-service | **⚠️ CrowdSec закомментирован** (`# - crowdsec`) — reason TBD |
| `sodix` | `sodix.org` | default-headers, https-redirect | (?) | personal |
| `logs` | `logs.sodix.org` | default-headers, https-redirect, basic-auth | logs | restricted |
| `tnas` | `tnas.sodix.org` | **crowdsec**, default-headers, https-redirect, basic-auth | tnas | |
| `jellyfin` | `jellyfin.sodix.org` | **crowdsec**, default-headers, https-redirect | jellyfin | |

## Existing middlewares inventory

| Middleware | Defined in | Purpose |
|---|---|---|
| `crowdsec` | `config.yml` | Plugin reference — bouncer + AppSec |
| `securityHeaders` (alias: `security-headers`) | `security-headers.yaml` | HSTS preload (63072000), X-CT-O, X-F-O=SAMEORIGIN, Referrer, hostsProxyHeaders |
| `default-headers` | `config.yml` | Lightweight headers preset |
| `https-redirect` | `https-redirect.yaml` | redirectScheme к https |
| `basic-auth` | `basic-auth.yml` | htpasswd users (admin tools, logs) |
| `gzip` (`compress`) | `config.yml` | response compression |
| `websocketHeaders` | `config.yml` | WS-friendly headers for Collabora |
| `rate-limit` | `rate-limit.yaml` | per-IP rate limit |
| `buffering` | `middlewares-buffering.yaml` | buffer tuning |
| `authentik` | `authentik.yaml` | forwardAuth → SSO |
| `nextcloud-chain` | `nextcloud/nextcloud-chain.yaml` | per-app chain |
| `tcp-whitelist` (`AllowListTCP`) | `AllowListTCP.yml` | IP allow-list for TCP routers |
| `push-stripprefix` | `config.yml` | strip /push prefix |

## Backup convention (пользователя, обязательно соблюдать)

```bash
# Перед любой правкой dynamic config'а:
cp /home/q/ubuntu_rep/traefik/config/config.yml \
   /home/q/ubuntu_rep/traefik/config/config.yml.backup-$(date +%Y%m%d-%H%M%S)
```

Старые backups накапливаются — periodic cleanup mini-task (отдельно). Stale patterns в текущей дир: `.save`, `.save.1`, `.save.2`, `.bak`, `.new` — не использовать для новых; новый стандарт **`.backup-YYYYMMDD-HHMMSS`**.

## Verification commands (after edit)

```bash
# 1. Traefik health (API ping):
ssh vds 'docker exec traefik wget -qO- http://localhost:8080/ping 2>/dev/null; echo'
# → expects "OK"

# 2. Recent errors in Traefik (last 10s):
ssh vds 'docker logs traefik --since 10s --tail 30 2>&1 | grep -iE "error|panic|fail"'

# 3. Router catalogue (live state):
ssh vds 'docker exec traefik wget -qO- http://localhost:8080/api/http/routers 2>/dev/null \
  | python3 -m json.tool | grep -E "name|status|rule" | head -30'

# 4. CrowdSec engine state:
ssh vds 'docker exec crowdsec cscli metrics 2>&1 | head -20'

# 5. Active CrowdSec decisions:
ssh vds 'docker exec crowdsec cscli decisions list -o human 2>&1 | head -20'

# 6. AppSec recent triggers:
ssh vds 'docker logs crowdsec --since 5m 2>&1 | grep -iE "appsec|blocked"'
```

## Cert resolver decision matrix

| Hostname pattern | Use resolver | Why |
|---|---|---|
| Single domain (`api.victory62.org`) | `letsencrypt` (HTTP-01) | Simpler — needs только port 80 reachable |
| Wildcard (`*.dev.victory62.org`) | `cloudflare` (DNS-01) | HTTP-01 не умеет wildcards |
| Несколько SANs на одном cert | `cloudflare` | Reuse существующего bundle |
| Domain без Cloudflare DNS | `letsencrypt` (HTTP-01) | DNS-01 нужен Cloudflare API token |

## Plugin versions (snapshot)

- `cloudflarewarp` v1.3.3 — restore real client IP behind Cloudflare proxy
- `crowdsec-bouncer-traefik-plugin` v1.3.3 — bouncer + AppSec client

**Plugin upgrade workflow** (не делать без явного approve):
1. Edit `traefik.yaml` `experimental.plugins.<name>.version`
2. Backup container state
3. `docker restart traefik` (production-impact)
4. Tail logs 30s for `plugin loaded` / errors
5. Test ключевые роуты

## Observability

- Traefik metrics at `:8082` (Prometheus format)
- `traefik-err.log` (ERROR level only — main signal)
- `access.log` (full)
- CrowdSec: `cscli metrics` + dashboards если подключён MetabaseAlerts

## Known issues / TODO

- ⚠️ **`victory62.org` router без CrowdSec** — `# - crowdsec` закомментировано. Причина TBD — расследовать (false-positive blocks? rate-limit shared with Rails-side?). Restore — отдельная задача.
- HTTP/3 в `traefik.yaml` закомментирован (instability при настройке). Можно вернуть когда будет ресурс на testing.
- Старые `.save`/`.bak`/`.new`/`.save.*` файлы в `/config/` — cruft. Cleanup mini-task.

## Related agent / skills

- Agent **`traefik-vds-ops`** — entry point для любых VDS ops
- Skill **`traefik-config-authoring`** — router/middleware/service patterns + safety workflow
- Skill **`crowdsec-policy-management`** — bouncer config + cscli + AppSec + scenarios
