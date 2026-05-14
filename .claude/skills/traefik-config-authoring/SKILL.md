---
name: traefik-config-authoring
description: Use when editing Traefik dynamic config (routers, middlewares, services, TLS) on the production VDS (`ssh vds`). Captures the file-provider layout, router/middleware/service patterns, TLS resolver decision matrix (cloudflare DNS-01 vs letsencrypt HTTP-01), and the obligatory safety workflow (backup → edit → log-tail verify → rollback-or-confirm). Reference paths and current inventory live in `.claude/docs/vds-infra-cheatsheet.md`. RELATED (.claude/docs/delegation-map.md) — pair with agent `traefik-vds-ops` for actual SSH execution; pair with skill `crowdsec-policy-management` when a router adds/removes CrowdSec bouncer middleware (those are coupled).
---

# Traefik dynamic config authoring

Применяй для любой правки роутеров / middlewares / services / TLS в Traefik dynamic config на VDS. Static config (`traefik.yaml`) — отдельная история, требует restart container'а.

**Reference paths cheatsheet:** `.claude/docs/vds-infra-cheatsheet.md` (lazy-read только когда нужны конкретные пути / inventory).

## The 7-step safety workflow (obligatory)

Никогда не правь dynamic config напрямую без этого цикла. Tradeoff: ~30 сек overhead vs 5 минут recovery при ломке prod.

```
1. READ       — текущий state файла:
                ssh vds 'cat /home/q/ubuntu_rep/traefik/config/<file>.yml'

2. DIFF       — показать pлан изменений пользователю (unified diff format)

3. BACKUP     — обязательно перед edit:
                ssh vds 'cp /home/q/ubuntu_rep/traefik/config/<file>.yml \
                          /home/q/ubuntu_rep/traefik/config/<file>.yml.backup-$(date +%Y%m%d-%H%M%S)'

4. EDIT       — записать новое содержимое через heredoc + scp:
                cat <<'EOF' | ssh vds 'cat > /home/q/ubuntu_rep/traefik/config/<file>.yml'
                <new content>
                EOF
                # или scp /tmp/local-edit.yml vds:/home/q/ubuntu_rep/traefik/config/<file>.yml

5. VERIFY     — Traefik hot-reload подхватывает за <1s, ошибки идут в err log:
                sleep 2
                ssh vds 'docker logs traefik --since 10s --tail 30 2>&1 | grep -iE "error|panic|fail"'
                # пусто = OK; есть ошибки → step 6

6. ROLLBACK   — если ERR в logs:
                ssh vds 'mv /home/q/ubuntu_rep/traefik/config/<file>.yml.backup-<TS> \
                          /home/q/ubuntu_rep/traefik/config/<file>.yml'
                # повторить step 5 — должно быть чисто

7. REPORT     — пользователю: что изменено, какой router/middleware affected,
                cleanup backup (опционально, если ok прошло > 1 дня)
```

Этот workflow **обязательный**. Никаких «уверен что не сломается» — даже опытные ops ошибаются в YAML indent.

## Router shape (canonical)

```yaml
http:
  routers:
    <router-name>:                       # уникальное имя, kebab-case
      entryPoints:
        - websecure                      # обычно HTTPS only
      rule: "Host(`api.victory62.org`)"  # ← backticks обязательны в YAML inline
      # альтернативы:
      #   "Host(`a.example.com`) || Host(`b.example.com`)"
      #   "Host(`api.victory62.org`) && PathPrefix(`/v1`)"
      #   "HostRegexp(`{subdomain:[a-z0-9-]+}.dev.victory62.org`)"
      middlewares:                       # chain — order matters!
        - crowdsec                       # security first
        - securityHeaders                # затем headers
        - https-redirect                 # затем redirect
        - gzip                           # compression в конце
      tls:
        certResolver: cloudflare         # ИЛИ letsencrypt — см. matrix ниже
        domains:                         # для wildcard / SAN'ов
          - main: "victory62.org"
            sans:
              - "*.victory62.org"
              - "api.victory62.org"
      service: <service-name>            # ↓ ниже в services:
      priority: 0                        # опц. — выше значит больше приоритет
```

**Common gotchas:**
- В YAML inline strings backticks (\`) внутри `Host()` — обязательно. Без них Traefik не парсит.
- Если router без `entryPoints:` — Traefik default `web,websecure` оба. Обычно надо явно указать `websecure`.
- `tls: {}` (пустой объект) = enable TLS с default cert resolver. Для product — всегда указывай явный resolver.
- Middlewares chain **порядок имеет значение** — security/auth первыми, decoration (gzip) последним.

## Cert resolver decision matrix

| Hostname | resolver | Why |
|---|---|---|
| Single domain `api.victory62.org` | **letsencrypt** (HTTP-01) | Простой, нужен только port 80 reachable |
| Wildcard `*.dev.victory62.org` | **cloudflare** (DNS-01) | HTTP-01 не умеет wildcards |
| Несколько SAN'ов на одном cert | **cloudflare** | Reuse существующего bundle |
| Domain без Cloudflare DNS | **letsencrypt** | DNS-01 требует CF API token |
| Cloudflare proxy ON (orange-cloud) | **cloudflare** | HTTP-01 не доходит до origin |

Existing certs живут в `/home/q/ubuntu_rep/traefik/data/acme.json` (perms 600). НЕ читать через шумные команды.

## Middleware shape

### Inline (defined in `config.yml`)

```yaml
http:
  middlewares:
    <middleware-name>:
      <type>:
        <key>: <value>
        ...
```

### Common types

```yaml
# 1. Headers
default-headers:
  headers:
    customResponseHeaders:
      X-Powered-By: ""
    customRequestHeaders:
      X-Forwarded-Proto: "https"

# 2. Redirect
https-redirect:
  redirectScheme:
    scheme: https
    permanent: true

# 3. BasicAuth (htpasswd-style)
admin-basic-auth:
  basicAuth:
    users:
      - "admin:$apr1$..."

# 4. Rate limit
api-rate-limit:
  rateLimit:
    average: 100        # req/s
    burst: 200
    period: "1s"

# 5. Plugin (CrowdSec example — already in production)
crowdsec:
  plugin:
    crowdsec-bouncer:
      enabled: true
      crowdsecMode: stream
      crowdsecAppsecEnabled: true
      # ... (см. cheatsheet)

# 6. Compress
gzip:
  compress: {}                  # default settings — ratio, encodings

# 7. StripPrefix
api-stripprefix:
  stripPrefix:
    prefixes:
      - "/api/v1"

# 8. ForwardAuth (SSO via Authentik — pattern из authentik.yaml)
authentik:
  forwardAuth:
    address: "http://authentik:9000/outpost.goauthentik.io/auth/traefik"
    trustForwardHeader: true
    authResponseHeaders:
      - X-Authentik-Username
      - X-Authentik-Groups
```

### Chain middleware (compose существующих)

```yaml
secured:
  chain:
    middlewares:
      - crowdsec
      - default-headers
      - basic-auth
      - https-redirect
```

Use chain когда несколько роутеров используют одинаковый набор — DRY.

## Service shape

```yaml
http:
  services:
    <service-name>:
      loadBalancer:
        servers:
          - url: "http://victory-web:3000"       # обычно internal docker DNS
          # ИЛИ:
          - url: "https://192.168.1.10:8443"     # external IP
        # опционально — health-check:
        healthCheck:
          path: "/health"
          interval: "30s"
          timeout: "5s"
        # опц. — sticky sessions:
        sticky:
          cookie:
            name: "lb_session"
```

**Critical:** `serversTransport.insecureSkipVerify: true` уже в static config — поэтому `https://` backend с self-signed работает. Но если backend цепляет нормальный cert — Traefik проверит chain.

## Where to put new config?

| What you're adding | File |
|---|---|
| Новый router + service для существующего домена | `config.yml` (main) |
| Общий middleware (используется ≥2 роутерами) | новый файл `<purpose>.yaml` в `/config/` |
| Per-app chain (Nextcloud-style) | `<app>/`-сабфолдер (как `nextcloud/nextcloud-chain.yaml`) |
| Tweak уже существующего middleware (security-headers) | тот же файл где он определён (`security-headers.yaml`) |

Не создавай файлы без необходимости — Traefik парсит весь `/config/` при каждом edit, лишние файлы = slower reload.

## Verification deep-dive

### Router live state (после edit)

```bash
ssh vds 'docker exec traefik wget -qO- http://localhost:8080/api/http/routers \
  | python3 -m json.tool | grep -E "\"name\"|\"status\"|\"rule\""' | head -40
```

Status values:
- `enabled` — Traefik подхватил
- `disabled` — bad config, route не activated (см. err log)
- `warning` — partial — заглядывать в err log

### Middleware live state

```bash
ssh vds 'docker exec traefik wget -qO- http://localhost:8080/api/http/middlewares \
  | python3 -m json.tool | head -40'
```

### Specific error tail

```bash
ssh vds 'tail -50 /home/q/ubuntu_rep/traefik/logs/traefik-err.log'
# vs:
ssh vds 'docker logs traefik --since 1m --tail 50 2>&1 | grep -iE "error|fail"'
```

Оба валидны — log file persistent, docker logs ограничено retention.

## Anti-patterns

- ❌ Edit `config.yml` без backup → catastrophic if Traefik не парсит
- ❌ Restart `docker restart traefik` для dynamic edit — не нужен! Hot-reload работает
- ❌ Skip verify step — silent failures дешевле обнаружить через лог, чем через user-report
- ❌ Удалить router → удалить service сразу же — оставь service на 24h как fallback
- ❌ Изменить middleware name inline — все ссылающиеся routers сломаются (`could not find middleware`)
- ❌ Trailing whitespace в `Host()` — Traefik парсит но матч не работает
- ❌ Mix `:80` и `:443` в одном router без redirect — клиенты залипают на :80

## Edge cases

### Router rule precedence

При collision двух роутеров с overlapping `Host()`:
- Тот, что с более высоким `priority:` выиграет
- Без `priority:` — Traefik вычисляет complexity-score (HostRegexp проигрывает Host)

При проблемах с routing — добавь `priority: 100` (или выше) более specific'у.

### Middleware order — анекдотический gotcha

```yaml
middlewares:
  - https-redirect          # 1) redirect к https
  - basic-auth              # 2) auth check
```

vs

```yaml
middlewares:
  - basic-auth              # 1) auth check
  - https-redirect          # 2) redirect к https
```

Первый — клиент по HTTP редиректится → потом auth check на HTTPS. Второй — клиент по HTTP получает auth challenge → потом редирект (loop).

**Правильно:** redirect ВСЕГДА first.

### Hot-reload fails to apply

Если Traefik по логам OK, но live router state не изменился:
1. Проверь typo в имени файла — `.yml` vs `.yaml` оба работают, но subdir файлы могут быть skip'нуты
2. Проверь permissions — `ls -la /home/q/ubuntu_rep/traefik/config/<file>` должен быть `-rw-rw-r--`
3. Hard fallback: `docker exec traefik traefik` чтобы заставить reread (НЕ restart!) — не работает на v3, нужен `docker restart traefik`

## When to hand off

- ⚙️ Производственный rollout новых сервисов → пиши `bin/claude-inbox send` в victory-session, чтобы Rails-side компонент был ready
- 🔐 Изменения middleware involving CrowdSec → координируйся со skill `crowdsec-policy-management`
- 🚨 Plugin upgrade (cloudflarewarp, crowdsec-bouncer) → отдельный subplan, требует static config edit + container restart
- 📊 Metrics endpoint / dashboard → за Traefik dashboard есть, но безопаснее обновлять через agent отдельной сессией
