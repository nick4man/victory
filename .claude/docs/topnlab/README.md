# Topnlab API — docs hub

Source: 4 PDF документации Topnlab API, конвертированные в markdown (98% coverage, structure preserved, 184 JSON-fence'ов сохранены). Размер суммарно ~119 KB (~30k токенов) — читай лениво, по разделам.

## Зачем эта папка существует

1. **Текущая интеграция** — у victory62 уже подключена синхронизация с Topnlab MLS через `app/services/topnlab/`, `app/services/mls_sync/`, 8 джобов и webhook-контроллер. Доки нужны как референс при добавлении/исправлении интеграции.
2. **Стратегическая цель** — миграция на **собственную CRM**. Эти доки = чёткий снимок того что Topnlab умеет, какие domain-сущности у него есть, какие поля он шлёт. На этой основе проектируется свой аналог. См. `migration-roadmap.md`.

## Индекс файлов

| Раздел | Файл | Размер | О чём |
|---|---|---|---|
| **Listings / МЛС** | `listings-and-mls.md` | 27 KB / 12 стр | Получение id карточек объектов/заявок/услуг, параметры объектов, МЛС-данные. Главный файл для синхронизации каталога. |
| **Call Center** | `call-center.md` | 16 KB / 9 стр | Интеграция Asterisk-телефонии: создание заявок из звонков, смена ответственного, фиксация звонков. |
| **Reports** | `reports.md` | 7 KB / 4 стр | API создания/редактирования/удаления отчётов в разделах Topnlab. Самый компактный раздел. |
| **Clients fields** | `clients-fields.md` | 70 KB / 30 стр | Полный справочник полей клиентов (физ.лица, юр.лица, дети, подписанты). Самый объёмный — читай по конкретной сущности через grep. |
| **Migration roadmap** | `migration-roadmap.md` | — | Скелет миграции с Topnlab на собственную CRM. Не доки, наш план. |

## Как использовать

### Для текущей работы

Если делаешь правки в:
- `app/services/topnlab/*` → начинай с `listings-and-mls.md` или `reports.md` (в зависимости от области)
- `app/services/mls_sync/listing_mapper.rb` → смотри `listings-and-mls.md` секции про параметры объектов
- `app/jobs/topnlab_*_job.rb` → соответствующая тема в `listings-and-mls.md`
- `app/controllers/webhooks/topnlab_*` → `listings-and-mls.md` (webhooks)
- работа с клиентами (Inquiry, Lead) → `clients-fields.md` через grep `field_name`
- телефония → `call-center.md`

### Для миграционных решений

Каждая сущность из Topnlab → отображается в нашу domain-модель. См. `migration-roadmap.md` для текущего map'инга.

## Поиск

Файлы большие — лучше через `grep -n "ключевое_слово"` или Serena's `find_symbol`-style поиск по smell-секциям.

В `clients-fields.md` структура такая:
- 11 H-секций (`## 1.` … `## 11.`)
- 184 JSON-fence'ов с примерами request/response

Используй `grep -n "^##" clients-fields.md` для оглавления.

## Версия и обновление

Доки от 09.05.2026 (mtime PDF). Если Topnlab API меняется — рекоммендация:
1. Сохранить новые PDF в `~/`
2. `pdftotext -layout` → manually fix bullet points/headings if needed
3. Заменить файлы здесь
4. Update `migration-roadmap.md` если изменения затрагивают domain-модель

## Связанные файлы victory62

- `app/services/topnlab/staff_sync_service.rb`, `app/services/topnlab/stats_client.rb`
- `app/services/mls_sync/{listing_mapper,topnlab_sync_service}.rb`
- `app/jobs/topnlab_{staff_sync,property_import,photo_sync,sync,orders_sync,note_push}_job.rb`
- `app/jobs/refresh_topnlab_stats_job.rb`
- `app/controllers/webhooks/topnlab_reports_controller.rb`
- `app/models/topnlab_sync_run.rb`
- `app/models/{mls_listing,external_listing}.rb`
- `.claude/agents/topnlab-api-expert.md` — субагент, читающий эти доки лениво

## TG dev chat для тестовых отчётов

`TELEGRAM_STAFF_CHAT_ID = -1003937910508` — dev+owner чат. Можно слать туда тестовые выгрузки/отчёты при отладке Topnlab-интеграции.
