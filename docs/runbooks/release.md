# Релиз и выкатка (с 1.0, 05.10.26)

Прод — compose-проект `victory` в `/home/q/victory` на хосте `victory`. Код
живёт в образах, не в чекауте; чекаут нужен ради `docker-compose.yml`, `.env*`,
`storage/` и скриптов `bin/`.

## Собрать релиз

1. На ветке релиза: `printf '1.0.1\n' > VERSION`, коммит, PR в `main`, ревью, merge.
2. Workflow `.github/workflows/build.yml` на merge в `main` собирает и пушит в
   GHCR тег `sha-<7>` каждой службы; коммит, меняющий `VERSION`, дополнительно
   получает тег `<версия>`. То есть после merge релизного PR образы обычно уже
   в реестре — шаг 3 нужен, только если VERSION-тег надо натянуть на более
   ранний sha или CI не запушил.
3. Довесить `<версия>` на уже собранный CI образ без локальной сборки:
   `bin/release --from-ci` на прод-хосте в чекауте `main` на нужном коммите
   (проверяет наличие `sha-<7>` в реестре и натягивает тег через imagetools).
   Fallback без CI: `bin/release --push` — собрать локально и запушить
   (`--check` — только показать). Образы:
   `ghcr.io/nick4man/victory-{web,conveyor,publisher,zhk-registry}:{<версия>,sha-<7>}`.
4. Тег в git: `git tag -a v<версия> -m 'release <версия>' && git -c http.version=HTTP/1.1 push origin v<версия>`.

## Выкатить

`bin/rollout <версия>` — бэкап → pull → `compose up -d` → health → `bin/smoke` → `bin/prod-mark`.
Простой web ≈ 30–60 с (стоп старого контейнера, старт нового, `db:prepare`).
Со включённым конвейером: `bin/rollout <версия> --profile conveyor`.

## Обновить одну службу

Общий тег лежит в `.env.deploy` (`VICTORY_TAG`). Override на службу — своя переменная:

| Служба | Переменная | Образ |
|---|---|---|
| web + sidekiq | `WEB_TAG` | victory-web |
| conveyor | `CONVEYOR_TAG` | victory-conveyor |
| publisher | `PUBLISHER_TAG` | victory-publisher |
| zhk-registry | `ZHK_TAG` | victory-zhk-registry |

Пример — выкатить новый реестр ЖК, не трогая сайт:

```bash
echo 'ZHK_TAG=1.0.1' >> .env.deploy
bin/rollout 1.0.0 --services zhk-registry --skip-backup
```

`bin/rollout` принимает общий тег первым аргументом; override из `.env.deploy`
сильнее него и переживает следующие выкатки. Вернуть службу на общий тег —
удалить строку из `.env.deploy`.

## Откат

`bin/rollout <предыдущая версия>`. Теги прошлых релизов — `git tag -l 'v*'` и
`docker image ls ghcr.io/nick4man/victory-web`. Миграции назад не едут: если
релиз менял схему, сначала `docker compose exec web bin/rails db:rollback`
в контейнере нового образа, потом rollout старого. Бэкап перед каждой выкаткой
— `bin/backup db` (дамп шифруется gpg), восстановление — `restore.md`.

## Профили

- `conveyor` — конвейер новостей: `news-db`, `conveyor`, `publisher`. Включать
  после переезда данных с chat (`cutover-1.0.md`) и заполненных
  `.env.conveyor`, `.env.publisher`, `NEWS_DB_PASSWORD` в `.env.deploy`:
  `docker compose --profile conveyor up -d`.
- `audit` — audit-engine; `.env.audit` с `AUDIT_DB_PASSWORD` обязателен (compose
  его больше не требует сам — проверять руками), стек пока живёт в архиве на хосте chat.
