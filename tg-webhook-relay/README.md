# Telegram Webhook Relay (Cloudflare Worker)

Edge-relay для приёма Telegram webhook'ов на Cloudflare и проброса на
`https://victory62.org/webhooks/telegram`. Обход блокировки TG IP-диапазонов
на хост-уровне prod-сервера.

## Архитектура

```
Telegram (91.108.x / 149.154.x)
  ↓ POST webhook
Cloudflare Worker (EU/RU edge — IP 104.16.x / 162.158.x)
  ↓ POST forward
victory62.org/webhooks/telegram (наш firewall видит обычный CF HTTPS)
  ↓
Rails InboundProcessor
```

## Deploy

Предусловия:
- Аккаунт Cloudflare (бесплатный) — <https://dash.cloudflare.com/sign-up>
- Node.js + npm на твоей машине

```bash
# 1. Установить wrangler (или используй npx)
npm install -g wrangler

# 2. Залогиниться (OAuth в браузере)
wrangler login

# 3. Из этой директории — deploy
cd tg-webhook-relay
wrangler deploy
```

После `wrangler deploy` ты увидишь:

```
Uploaded victory-tg-relay (XX sec)
Published victory-tg-relay (XX sec)
  https://victory-tg-relay.<your-subdomain>.workers.dev
```

Скинь этот URL разработчику — он переключит webhook через
`bin/rails telegram:webhook:setup` с `TELEGRAM_WEBHOOK_URL=<url>`.

## Тест без TG

```bash
# Worker должен ответить 200 на POST (или 405 на GET с подсказкой)
curl -X POST https://victory-tg-relay.<sub>.workers.dev \
  -H 'Content-Type: application/json' \
  -d '{}' \
  -w '\nHTTP=%{http_code} time=%{time_total}s\n'
```

Ожидаемо: `HTTP=200`, время <500ms. Worker сам POST'ил пустой webhook на
наш Rails (который вернул 200 — все TG-webhook'и принимаются всегда 200,
независимо от тела).

## Free план

Cloudflare Workers free tier:
- 100,000 запросов/день
- 10ms CPU/запрос
- Бесплатный TLS (LetsEncrypt автоматический)
- Бесплатный subdomain `*.workers.dev`

Наша нагрузка: ~1000 webhook/день. Запас 100x.

## Security

По умолчанию проверка secret token **отключена** (`EXPECTED_SECRET = ''`).
Это OK для small-scale продакшна (любой кто угадает URL может POST'ить нам,
но мы валидируем `update_id` + общую структуру TG payload в Rails).

Чтобы включить:

1. В `src/index.js` поставить `const EXPECTED_SECRET = 'your-random-secret';`
2. Передать тот же secret в `Telegram::Client#set_webhook(secret_token: '...')`
3. `wrangler deploy`
4. Re-run `bin/rails telegram:webhook:setup` с `TELEGRAM_WEBHOOK_SECRET=...` в ENV

## Откат / удаление

```bash
wrangler delete  # удалит Worker полностью
```

После этого на Rails — вернуть `TELEGRAM_POLLING_MODE=true` и
`bin/rails telegram:webhook:delete`.
