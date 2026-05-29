# Topnlab — кастомные поля fc_* для TG-бота АН «Виктори»

> Один раз перед стартом Phase 3. Без этих полей CRM-стороны интеграции
> работают в read-only режиме (бот не падает, но не пишет дополнительный
> контекст в Topnlab).

## Что нужно создать

В Topnlab Admin UI создай 8 кастомных полей на карточке **Order** (заказ-клиент,
тип `order`). Имена ровно как ниже — бот пишет в них напрямую через
`patch_entity(fields: { fc_* => value })`.

| Поле | Тип | Назначение | Кто пишет |
|------|-----|------------|-----------|
| `fc_first_contact_due` | datetime | Дедлайн первого контакта = `assigned_at + 30 мин`. Используется SLA-watchdog'ом и в Topnlab UI как индикатор спешности. | `LeadAssignment` после assign |
| `fc_next_action_at` | datetime | Дедлайн следующей задачи по сделке. | `Commands::Task` при создании Task |
| `fc_stage` | string | Текстовое зеркало нашего `LeadEvent.current_stage` (`new`, `first_contact`, `show`, `contract`, `deal`, `closed_won`, `closed_lost`). Read-only в Topnlab UI. | `LeadStageTransition` (Phase 4) |
| `fc_lead_source_tg` | boolean | `true` если лид пришёл через TG-бота (сайт-форма + auto-route в #ОЦЕНКА считается тоже TG-source). | `LeadAssignment` |
| `fc_tg_lead_event_id` | integer | id `LeadEvent` в нашей БД — для cross-link «из CRM посмотри что в TG». | `LeadAssignment` |
| `fc_is_spam` | boolean | `true` после нажатия [🚫 Спам] на якорной карточке. | `Callbacks::SpamCallback` |
| `fc_tg_assigned_user` | integer | Topnlab user_id назначенного агента (как `users.id` из `/getUsers`). Дублирует поле «Ответственный» — в нашей мапке нужно для аналитики. | `LeadAssignment` |
| `fc_tg_topic_key` | string | Где сейчас лежит якорь (`apartments` / `houses` / `lots` / `commercial` / `rent` / `mortgage` / `appraisal` / `taxes` / `insurance` / `escrow` / `deal`). Обновляется при каждом /route. | `AnchorMigrator` |

## Где создавать в UI

Topnlab → Настройки → Кастомные поля → Тип сущности: «Заказ» → +Добавить поле.

Имя поля — точно `fc_first_contact_due` etc. (с префиксом `fc_`).
Тип — как в таблице выше.
Видимость в карточке — по желанию (рекомендуется показывать `fc_stage`, `fc_first_contact_due`, `fc_tg_topic_key`).

## Что если поля нет?

`patch_entity` в Topnlab при unknown ключе либо вернёт ошибку, либо
проигнорирует (зависит от API). В обоих случаях бот:
- Логирует `[LeadAssignment] patch_entity fc_* failed: ...`
- Продолжает основную операцию (assign / route / spam)
- Лид этим не страдает

То есть **создание полей опционально** — но без них теряется аналитическая
ценность в Topnlab UI.

## Проверка после создания

```bash
docker compose exec -T web bin/rails runner '
  client = Topnlab::Client.new
  # Возьми любой order_id из CRM
  res = client.patch_entity(id: 12345, type: "order", fields: {
    fc_lead_source_tg: true,
    fc_tg_topic_key: "apartments"
  })
  p res
'
```

Если поля существуют — `{"status" => "ok"}`. В Topnlab UI обновится карточка
order'а 12345.
