# IndexNow protocol — setup guide

> Единый push-endpoint для уведомления **Bing, Yandex, Brave (Yep), Naver, DuckDuckGo, Seznam** одним HTTP-запросом, когда у вас публикуется/обновляется страница. Огромный win для скорости индексации новых listings и news.

## TL;DR

1. Сгенерировать random API key (`openssl rand -hex 32`)
2. Положить в `.env` как `INDEXNOW_API_KEY`
3. Hosted at `https://victory62.org/<key>.txt` (содержит сам key)
4. После publish Property/Article — POST в `https://api.indexnow.org/indexnow` с URL list
5. Поисковики crawl-сами проверяют hosted key и принимают уведомление

## Что даёт IndexNow

| Без IndexNow | С IndexNow |
|---|---|
| Поисковик crawl'ит по своему расписанию (часы-дни-недели) | Поисковик заходит на URL в течение **минут-часов** |
| Нужно подождать пока re-crawl заметит изменения | Push при каждом изменении |
| Только sitemap.xml как сигнал | Push + sitemap (дополняют) |

Поддерживают (на 2026):
- ✅ Bing
- ✅ Yandex
- ✅ Brave (Yep search engine)
- ✅ Naver
- ✅ Seznam
- ✅ DuckDuckGo (через Bing data)
- ❌ Google (свой эндпоинт через Search Console — не IndexNow protocol)

Спецификация: https://www.indexnow.org

## Setup

### Шаг 1: Сгенерировать API key

```bash
openssl rand -hex 32
# например: c3a5f2b1e7d4a8b6c9f0e3d5a7b1c4f8e0a3b6d9c2f5a8e1b4d7c0f3a6e9d2c5
```

Сохранить ⚠️ **в безопасном месте**. Key должен быть 8-128 hex chars; 64 chars (32 bytes) — comfortable size.

### Шаг 2: Положить в production `.env`

```bash
# .env (production)
INDEXNOW_API_KEY=c3a5f2b1e7d4a8b6c9f0e3d5a7b1c4f8e0a3b6d9c2f5a8e1b4d7c0f3a6e9d2c5
```

В `.env.example` добавлю placeholder:

```bash
INDEXNOW_API_KEY=replace_with_openssl_rand_hex_32
```

### Шаг 3: Verify key file после deploy

```bash
curl https://victory62.org/c3a5f2b1e7d4a8b6c9f0e3d5a7b1c4f8e0a3b6d9c2f5a8e1b4d7c0f3a6e9d2c5.txt
```

Должно вернуть plain text:
```
c3a5f2b1e7d4a8b6c9f0e3d5a7b1c4f8e0a3b6d9c2f5a8e1b4d7c0f3a6e9d2c5
```

(весь файл = значение key без переносов)

Реализация: контроллер `IndexNowKeyController#show` отдаёт plain text. Route: `get '/:key.txt' => 'index_now_key#show', constraints: { key: /[a-fA-F0-9]{8,128}/ }`. Контроллер сравнивает param с `ENV['INDEXNOW_API_KEY']` и отдаёт key либо 404.

## Использование

### Автоматически — на Property/Article publish

В моделях `Property` и `Article` callback (Phase 2B Item 6 этим занимается):

```ruby
# app/models/property.rb (Item 6 добавит)
after_update :notify_indexnow, if: :saved_change_to_status_to_active?

private

def saved_change_to_status_to_active?
  saved_change_to_status? && status_active?
end

def notify_indexnow
  url = Rails.application.routes.url_helpers.property_url(self, host: 'victory62.org', protocol: 'https')
  Seo::IndexNowNotifyJob.perform_later(url: url)
end
```

### Manual — батчем (через rake)

Полезно когда обновили большую группу listings, или хотите re-index sitemap:

```ruby
# lib/tasks/index_now.rake (на будущее, если понадобится)
namespace :index_now do
  desc 'Notify IndexNow about all active properties'
  task properties: :environment do
    urls = Property.where(status: :active).limit(10_000).map do |p|
      Rails.application.routes.url_helpers.property_url(p, host: 'victory62.org', protocol: 'https')
    end
    Seo::IndexNowNotifier.new(urls).call
  end
end
```

## Service & Job pattern

```ruby
# app/services/seo/index_now_notifier.rb (Item 6 создаст)
class Seo::IndexNowNotifier
  ENDPOINT = 'https://api.indexnow.org/indexnow'
  HOST     = 'victory62.org'

  def initialize(urls)
    @urls = Array(urls).compact_blank
  end

  def call
    return :skip if ENV['INDEXNOW_API_KEY'].blank? || @urls.empty?

    body = {
      host:        HOST,
      key:         ENV['INDEXNOW_API_KEY'],
      keyLocation: "https://#{HOST}/#{ENV['INDEXNOW_API_KEY']}.txt",
      urlList:     @urls.first(10_000)
    }
    response = Faraday.post(ENDPOINT, body.to_json, 'Content-Type' => 'application/json')
    Rails.logger.info("[IndexNow] #{response.status} for #{@urls.size} URLs")
    response.status
  rescue StandardError => e
    Rails.logger.warn("[IndexNow] failed: #{e.class} #{e.message}")
    nil
  end
end
```

```ruby
# app/jobs/seo/index_now_notify_job.rb (Item 6 создаст)
class Seo::IndexNowNotifyJob < ApplicationJob
  queue_as :low_priority

  def perform(url:)
    Seo::IndexNowNotifier.new(url).call
  end
end
```

## Лимиты

- **10,000 URLs per request** (chunk if exceeded)
- **No daily quota** (но не spam'ить minor updates — поисковики могут downgrade trust)
- Принципы: только при **значимом изменении контента**, не на каждое minor field update

## Verification после deploy

1. Опубликовать тестовый Property (изменить status → active)
2. `tail -f log/production.log` → должна появиться строка `[IndexNow] 200 for 1 URLs` через несколько секунд
3. **Bing Webmaster** → URL Inspection → через 1-2ч URL появится в индексе
4. **Yandex.Webmaster** → Indexing → Recent indexing → URL должен быть там

Status codes от IndexNow:
- `200` OK — accepted
- `202` Accepted — pending validation
- `400` Bad request — check body format
- `403` Forbidden — key.txt не доступен по URL
- `422` Unprocessable — URL вне domain
- `429` Too many requests — slow down

## Anti-patterns

- ❌ Не вызывать IndexNow на каждый Property.save — только при значимом изменении (status change, price change > 5%, new images)
- ❌ Не использовать тот же key для разных доменов — нужен per-domain key
- ❌ Key file не в git — он живёт только в `.env` (сам key-файл служит как доказательство владения, не для public consumption)
- ❌ Не делать sync HTTP call в request — всегда через `_later` job

## Связанные доки

- `search-console-setup.md` — Google индексирует через Search Console (Google не поддерживает IndexNow)
- Yandex.Webmaster URL Submit — отдельный сервис от IndexNow, но Yandex IndexNow тоже принимает (через тот же endpoint)
- robots.txt — отдельный сигнал; IndexNow не заменяет sitemap, а дополняет
