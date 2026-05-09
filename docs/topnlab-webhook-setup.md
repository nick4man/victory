# Регистрация webhook URL Topnlab CRM

Topnlab отправляет уведомления о создании/редактировании карточек на наш сервер.
Регистрировать URL нужно **один раз вручную** в кабинете Topnlab — публичного API
для этого нет (см. `/home/q/document_pdf.md`, секция «Получать id карточек объектов,
заявок и услуг, которые были созданы и/или отредактированы в Topnlab»).

## Что регистрируется

Endpoint: `POST https://victory62.org/webhooks/topnlab`

Контроллер: `app/controllers/webhooks/topnlab_controller.rb` — обрабатывает
`type=realty` (объекты) синхронно через `TopnlabPropertyImportJob`. Прочие типы
(order/service) логируются — будут добавлены по мере необходимости.

## Шаги в Topnlab UI

1. Войти в Topnlab CRM под админ-аккаунтом агентства.
2. **Настройки → API → URL уведомлений** (точное название может отличаться;
   ищите раздел "Веб-хуки" или "Notifications").
3. Указать URL: `https://victory62.org/webhooks/topnlab`.
4. Включить уведомления для типов:
   - ✅ `realty` — объекты недвижимости (Продавцы, Арендодатели). Обязательно.
   - ✅ `order` — заявки покупателей и арендаторов. Опционально (получаем через
     cron-sync каждые 3 часа независимо).
   - ❌ `service` — услуговые заявки. Пропускаем, т.к. v1 не обрабатывает.
5. Сохранить настройки.

## Как проверить что работает

После регистрации:

1. Создать или отредактировать любой объект в Topnlab.
2. На нашей стороне: `docker compose logs web --since 2m | grep topnlab`.
3. Должны увидеть строки вида:
   ```
   Webhook Topnlab: id=12345 type=realty
   [ActiveJob] Enqueued TopnlabPropertyImportJob (Job ID: ...)
   ```
4. Через несколько секунд: `docker compose exec web bin/rails runner 'puts Property.last.title'`
   — изменения должны быть подтянуты.

## Если уведомления не приходят

- **Allow-list IP**: некоторые версии Topnlab отправляют webhook'и только с
  определённых IP. Если webhook не приходит, узнать у поддержки Topnlab их
  outgoing IPs и пробросить через Cloudflare Firewall (Page Rules).
- **Retry policy**: Topnlab перезапускает доставку при не-200. Endpoint
  всегда возвращает `head :ok`, но если приложение упало или Sidekiq стоит,
  логи покажут уровни ошибок.
- **Передача происходит по HTTP, не HTTPS** (хотя обычно поддерживают оба).
  URL `https://victory62.org/...` поддерживает оба, через redirect.

## Связанные файлы

- Контроллер: `app/controllers/webhooks/topnlab_controller.rb`
- Job: `app/jobs/topnlab_property_import_job.rb`
- Cron-sync (резервный путь): `app/jobs/topnlab_sync_job.rb` (каждые 30 мин)
- Документация API: `/home/q/document_pdf.md`
