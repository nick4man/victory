# schema/ — DDL базы конвейера новостей (`news-db`)

Контейнер `news-db` (образ `Dockerfile.postgres`: PostgreSQL 15 + pgvector)
выполняет эти файлы при **первом** старте пустого тома через
`/docker-entrypoint-initdb.d`, по алфавиту:

| Файл | Таблицы | Откуда снято 05.10.26 |
|---|---|---|
| `10-urgent_events.sql` | `urgent_events` (embedding `vector(3072)`) | `chat:audit-v2-postgres`, база `re_audit` — таблица жила внутри БД audit-engine, но в его alembic не входит |
| `20-posts_queue.sql` | `posts_queue`, `content_revisions`, `system_flags` + триггер `updated_at` | `chat:postgres-local`, база `re_audit` |

Оба — `pg_dump --schema-only --no-owner --no-privileges`; владельцев, прав и
паролей в файлах нет. Функция триггера добавлена руками: `pg_dump -t` функции
не выгружает.

Данные (≈170 МБ `urgent_events` с эмбеддингами, 10 МБ очередь) переезжают
отдельно — `pg_dump --data-only` по LAN в окне между прогонами коллектора,
процедура в `docs/runbooks/cutover-1.0.md`. На уже инициализированный том
initdb-скрипты повторно не выполняются; смена схемы после переезда — только
миграцией.

Проверка файлов на чистом Postgres:

```bash
docker run -d --name schema-check -e POSTGRES_PASSWORD=x -e POSTGRES_DB=news \
  -v "$PWD/services/urgent-news-collector/schema:/docker-entrypoint-initdb.d:ro" \
  viktory-postgres-pgvector:pg15-postgis36
sleep 8; docker logs schema-check 2>&1 | grep -iE 'error|fatal' ; docker exec schema-check psql -U postgres -d news -Atc '\dt'
docker rm -f schema-check
```
