---
service: audit-engine
owner: victory
kind: python-service
entrypoint: FastAPI, см. SKILL_API_CONTRACT.md
tests: не заведены — часть репатриации
deploy: bin/audit-stack up -d на хосте victory (профиль audit корневого docker-compose.yml); стек и данные re_audit переехали с chat 13.10.26
depends_on: none
ported_from: chat:~/.openclaw/workspace-it-dept/audit-engine-v2/
port_status: in-progress
repatriate_by: 31.03.27
---

# audit-engine

Движок инвестиционного аудита недвижимости: индекс эффективности, Монте-Карло,
гедонистическая регрессия, PDF-отчёты. FastAPI, 24 эндпоинта — контракт в
`SKILL_API_CONTRACT.md`.

## Владение

**Права наши.** Код писался для агентства, и разбирать его будем мы.
13.10.26 стек и данные `re_audit` переехали с хоста `chat` на victory
(compose-профиль `audit`, `bin/audit-stack`); контейнеры `audit-v2-*` на
chat остановлены.

`port_status: in-progress` — переезд выполнен, но хвост остаётся: нет тестов
и жив `upstream-sync.sh`. Срок в `repatriate_by` не дедлайн для кого-то, а
дата, после которой `bin/services-check` начнёт напоминать о незакрытом
хвосте: иначе «потихоньку доведём до ума» превращается в «никогда».

## Что нужно для репатриации

1. ~~Снять последнюю копию с хоста `chat` и зафиксировать её как нашу~~ —
   выполнено 13.10.26 (данные перенесены pg_dump'ом, без таблиц конвейера
   новостей — те уехали в `news-db` профиля `conveyor`).
2. Завести тесты — сейчас их нет ни одного, поэтому любое изменение движка
   проверить нечем.
3. Убрать `upstream-sync.sh` — после переноса тянуть будет неоткуда и незачем.
4. ~~Описать деплой docker-стека здесь же, а не в чужом каталоге devops~~ —
   `bin/audit-stack` + профиль `audit` корневого compose.

## Граница

Служба не импортирует ни другие каталоги `services/`, ни Rails-код. Rails
ходит в неё по HTTP, по контракту из `SKILL_API_CONTRACT.md`.
