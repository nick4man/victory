# Audit Engine v2.0 Stack

Docker Compose стек для развертывания Audit Engine v2.0 (FastAPI + PostgreSQL + Redis).

## Структура
- **API**: FastAPI приложение на порту 8100.
- **PostgreSQL**: База данных v16 на порту 5433 (не конфликтует с основным PG).
- **Redis**: Кэш/очереди на порту 6379.

## Быстрый запуск
```bash
./start.sh
```

## Управление
- **Остановка**: `./stop.sh`
- **Миграции**: `./migrate.sh`
- **Логи**: `docker compose logs -f`

## Важные порты
- API: `8100`
- PostgreSQL: `5433`
- Redis: `6379`

## Health Check
```bash
curl http://localhost:8100/api/v2/health
```
