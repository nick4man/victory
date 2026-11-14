# Автоматизация Avito: синхронизация чатов

## Обзор

Интеграция получает входящие сообщения из Avito Messenger через вебхуки V3,
связывает их с объектом недвижимости по `item_id` и пересылает в Telegram
(или другой настроенный канал).

## Endpoint

```
POST /webhooks/avito?token=<AVITO_WEBHOOK_SECRET>
```

Контроллер отвечает `200 OK` после проверки подписи и постановки задачи
в очередь. Обработка происходит асинхронно в Sidekiq. Если секрет не
настроен, контроллер отвечает `501 Not Implemented` и запрос не принимает.

## Аутентификация

Avito не подписывает вебхуки общим секретом. При регистрации webhook URL через
`POST /messenger/v3/webhook` добавьте токен в query string:

```
https://victory62.org/webhooks/avito?token=<AVITO_WEBHOOK_SECRET>
```

Rails сверяет `token` с `ENV['AVITO_WEBHOOK_SECRET']`. Переменная обязательна:
если она не задана, контроллер отвечает `501 Not Implemented` и не принимает
запросы — как и остальные webhook-контроллеры проекта.

## Формат payload

Avito Messenger V3 шлёт JSON вида:

```json
{
  "payload": {
    "type": "message",
    "value": {
      "id": "msg_123",
      "chat_id": "chat_456",
      "chat_type": "u2i",
      "author_id": 987654,
      "user_id": 123456,
      "item_id": 111222333,
      "type": "text",
      "created": 1699999999,
      "published_at": "2023-11-14T12:00:00Z",
      "read": null,
      "content": {
        "text": "Здравствуйте, можно посмотреть квартиру?"
      }
    }
  }
}
```

Поля:

| Поле        | Тип      | Описание                                              |
|-------------|----------|-------------------------------------------------------|
| `id`        | string   | Уникальный id сообщения (используется для дедупликации) |
| `chat_id`   | string   | Id чата                                               |
| `author_id` | integer  | Id отправителя в Avito                                |
| `user_id`   | integer  | Id аккаунта-получателя (наш аккаунт в Avito)          |
| `item_id`   | integer  | Id объявления Avito (только для `chat_type: u2i`)    |
| `type`      | string   | Тип сообщения: `text`, `image`, `call`, ...           |
| `content`   | object   | Содержимое сообщения                                  |

## Определение объекта

Сообщение связывается с `Property`, если находится запись:

```ruby
Property.find_by(external_source: 'avito', external_id: item_id.to_s)
```

Если объект не найден, сообщение всё равно сохраняется и маршрутизируется с
упоминанием `item_id`.

## Маршрутизация в канал

По умолчанию сообщения уходят в Telegram. Настраивается переменными:

| Переменная               | Описание                                                              |
|--------------------------|-----------------------------------------------------------------------|
| `AVITO_TARGET_CHANNEL`   | Канал доставки (`telegram` по умолчанию)                              |
| `AVITO_TELEGRAM_CHAT_ID` | Целевой чат/группа в Telegram. Если пуста — fallback на `TELEGRAM_STAFF_CHAT_ID` |

Для текстовых сообщений отправляется `sendMessage` с HTML-разметкой.
Для изображений (`type: image`) отправляется `sendPhoto` с caption.

## Обработка ошибок и retry

- Контроллер отвечает `200 OK` сразу после постановки задачи в очередь.
- `Avito::InboundProcessorJob` настроен на 3 retry в Sidekiq.
- Дедупликация по `message_id` через уникальный индекс на `AvitoMessage`.
  Если сообщение уже сохранено, но `routed_at` пустой (упала маршрутизация),
  при retry оно будет до-маршрутизировано.
- `AvitoWebhookAck` создаётся только после успешной доставки в канал.
- Ошибки Telegram (`Telegram::Client::Error`) логируются и пробрасываются,
  чтобы Sidekiq повторил попытку.

## Модели

- `AvitoMessage` — сохранённое сообщение со ссылкой на `Property` и raw payload.
  Мягкое удаление через `deleted_at` + `default_scope { not_deleted }`.
- `AvitoWebhookAck` — audit-запись об успешно обработанном `message_id`.
  Также поддерживает мягкое удаление.

## Переменные окружения

```bash
# Обязательные для приёма webhook
AVITO_WEBHOOK_SECRET=...

# Канал доставки (по умолчанию telegram)
AVITO_TARGET_CHANNEL=telegram

# Целевой Telegram-чат. Fallback: TELEGRAM_STAFF_CHAT_ID
AVITO_TELEGRAM_CHAT_ID=-1001234567890

# Для отправки в Telegram
TELEGRAM_BOT_TOKEN=...
TELEGRAM_STAFF_CHAT_ID=-1001234567890

# Для генерации ссылок на объект
APP_DOMAIN=victory62.org
```

## Пример тестового вызова

```bash
curl -X POST "https://victory62.org/webhooks/avito?token=$AVITO_WEBHOOK_SECRET" \
  -H "Content-Type: application/json" \
  -d '{
    "payload": {
      "type": "message",
      "value": {
        "id": "msg_123",
        "chat_id": "chat_456",
        "chat_type": "u2i",
        "author_id": 987654,
        "user_id": 123456,
        "item_id": 111222333,
        "type": "text",
        "created": 1699999999,
        "content": { "text": "Можно посмотреть?" }
      }
    }
  }'
```
