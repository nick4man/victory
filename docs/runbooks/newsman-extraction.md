# Вынос новостного конвейера (newsman) в отдельный репозиторий

Бриф-анализ по issue #190. Деливерабл — сравнение опций и план миграции.
**Это не решение**: финальную опцию утверждает владелец. Документ не меняет
поведение конвейера; правки кода — только отдельными issue после утверждения.

Дата анализа: 09.11.26. Состояние: конвейер жив в профиле `conveyor` корневого
compose на хосте `victory` (cutover 13.10.26, `docs/runbooks/cutover-1.0.md`),
посты каждые 15 минут, образы `ghcr.io/nick4man/victory-{conveyor,publisher}`.

## 1. Что именно выносим

Конвейер — три каталога `services/*` и их инфраструктурный контур:

| Компонент | Сейчас | Роль |
|---|---|---|
| `services/urgent-news-collector/` | код + Dockerfile + crontab.docker + schema/ + тесты | коллектор и триггеры (urgent / digest / bank_rates) |
| `services/content-publisher/` | код + Dockerfile | публикатор `posts_queue` → @rznvictory |
| `services/chat-host-cron/` | 1 bash-скрипт | `MIRROR_SCRIPT`: зеркало постов в `/webhooks/news_ingest` |
| compose: `news-db`, `conveyor`, `publisher` | корневой `docker-compose.yml`, профиль `conveyor` | рантайм на хосте victory |
| `.env.conveyor` / `.env.publisher` | хост victory, вне git | секреты |
| CI: job `services` в `build.yml` | репозиторий victory | сборка образов по изменениям каталогов |

Граница вынесения, которую предлагает этот документ: **код и сборка образов**
уезжают; **compose-манифесты, секреты, news-db, chat-host-cron и учёт** —
остаются в victory. Обоснование — в разделах 2–6.

`services/audit-engine/` и `services/zhk-registry/` вопрос не касаются:
у audit-engine свой хвост репатриации (до 31.03.27), zhk-registry — свой
независимый образ.

## 2. Опции структуры: сравнительная таблица

Оценка по пяти осям: независимость релизов конвейера, сложность для
агентов/CI (kanban-конвейер живёт в этом репо), риск простоя живого контура,
честность учёта владения, стоимость переезда.

| | A. Статус-кво (всё в victory) | B. Отдельный репо + submodule | C. Отдельный репо + subtree | D. Отдельный репо, связь только образом | E. Гибрид (D + compose/учёт в victory) |
|---|---|---|---|---|---|
| Независимость релизов | частичная: sha-образы конвейера собираются по изменениям каталога и катятся override'ом (`CONVEYOR_TAG`), но VERSION и релизный ритм общие с Rails | формальная: версия submodule — коммит в victory | слабая: subtree-мержи делаются из victory, ритм Rails | полная: свои теги, своя CI, свои sha-образы | полная (как D) |
| CI | один build.yml, матрица по каталогам | checkout с `submodules: true` везде; агенты в victory-checkout получают весь конвейер | сложные sync-мержи в CI; дубль истории | victory build.yml теряет 2 записи матрицы; новый простой workflow | как D |
| Риск для живого контура | нулевой (базовая линия) | gitlink фиксирует ревизию, но рискует пропущенный `submodule update` и незакоммиченный bump gitlink: агент правит код в submodule, а victory (и прод) остаются на старой ревизии; локальный `docker compose build` соберёт не то | рассинхрон `subtree pull` — две правды о коде | нулевой: victory вообще не видит исходников, только тег образа | нулевой (как D) |
| Учёт владения | честный: всё наше в одном дереве | split-brain: файл числится в двух репо (та же ловушка, из-за которой четыре каталога годами были «чужими», см. services/README.md) | как B | честный: код в своём репо = один владелец; victory хранит контракт (тег) | честный + явный: учёт остаётся в services-check |
| Стоимость переезда | 0 | средняя: импорт истории, submodule-гигиена, правка CI | высокая: история раздувается, мердж-барьер навсегда | низкая: `git filter-repo`, новый workflow, конец | низкая (как D) + точечная правка build.yml и манифестов учёта |

### Рекомендация: опция E (гибрид), фактически — D с явным списком того, что остаётся

Ключевое наблюдение: **контракт между victory и конвейером уже является
образом**. С cutover 1.0 прод работает на
`ghcr.io/nick4man/victory-conveyor:${CONVEYOR_TAG}` — victory не собирает и не
монтирует код конвейера, только тянет образ (`bin/rollout <тег> --services
conveyor --profile conveyor`, `docs/runbooks/release.md`). Единственные
исходники конвейера, которые реально читает victory, — schema initdb
(`services/urgent-news-collector/schema` монтируется в `news-db`) и
`MIRROR_SCRIPT` из chat-host-cron. То есть «модульность через исходники»
(submodule/subtree) решает задачу, которой в проде нет, и добавляет класс
рисков, которых в проде нет.

Почему не B (submodule): агентный конвейер (issue → kanban → PR) работает
worktree'ами этого репозитория; каждый checkout агента получает submodule в
detached HEAD, правка конвейера агентом потребует отдельной дисциплины
«push в submodule → bump в victory», и забытый bump молча откатывает прод.
Это ровно механика двойного владения, от которой 07.09.26 уходили.

Почему не C (subtree): история Rails-репо раздувается чужими коммитами, а
обратные синки (`subtree pull`) — ручной барьер, который встанет на первом
же «срочно поправить промпт». Для одного владельца subtree не даёт ничего,
чего не даёт `git filter-repo` при переезде.

Что E добавляет к D: compose-профиль `conveyor`, `.env.conveyor*`,
`news-db` (том + schema-initdb) и учёт служб остаются в victory — это
операционный контур хоста, а не код службы. Плюс явный учётный мост в
`bin/services-check` (раздел 6), чтобы служба не выпала из реестра.

Статус-кво (A) — честный конкурент: при низкой частоте правок конвейера
вынос может не окупиться. Окупаемость определяется процессом: отдельный
репо оправдан, если конвейеру нужны релизы/версии, не дожидающиеся ветки
`dev/upgrade` → main. Это вопрос владельцу (раздел 9).

## 3. CI/CD после выноса (п. 2 брифа)
**Сейчас.** `.github/workflows/build.yml`: job `prep` собирает матрицу
`conveyor:services/urgent-news-collector publisher:services/content-publisher
zhk-registry:services/zhk-registry` по diff с base/before; job `services`
строит и пушит `victory-<svc>:sha-<7>` (+ `<VERSION>` при релизе). VERSION
общий для Rails и служб: релиз Rails двигает и образ конвейера.

**После (опция E).**

- Новый репозиторий `nick4man/victory-conveyor` получает свой `build.yml`:
  python-тесты (`unittest`, как сейчас — без сети и БД), сборка и пуш
  `ghcr.io/nick4man/victory-conveyor:sha-<7>` на каждый merge в main + тег
  `<VERSION>` по файлу VERSION конвейера (независимый от Rails). То же для
  `victory-publisher`.
- В victory `build.yml` из матрицы исчезают `conveyor` и `publisher`
  (остаётся `zhk-registry`): вместе с каталогами уезжает тестовый слой
  их Dockerfile'ов (`RUN python3 -m unittest …`) — именно там python-тесты
  конвейера гоняются сейчас, `lint.yml` их и не содержал (только
  `bin/services-check`), и `services-check` теряет два каталога (раздел 6).
- Версионирование: конвейер живёт своими git-тегами/версией; victory
  **пинит** конкретный образ в `.env.deploy` (`CONVEYOR_TAG` /
  `PUBLISHER_TAG`). Раскатка конвейера без Rails-релиза — по той же
  механике, что и в `docs/runbooks/release.md` («Обновить одну службу»):
  зафиксировать override в `.env.deploy` и перекатить только службы
  конвейера (`bin/rollout <общий тег> --services conveyor,publisher
  --profile conveyor`); override сильнее общего тега и переживает
  следующие выкатки Rails. Shell-prefix `CONVEYOR_TAG=… docker compose
  up` **не годится**: он живёт одним вызовом, `.env.deploy` не обновит,
  и следующая выкатка Rails увезёт конвейер на общий `VICTORY_TAG`.
  Раскатка Rails не трогает конвейер, и наоборот.
- Канал поставки staging/прод не меняется: тот же GHCR, тот же `bin/rollout`/deploy-gate; staging-профиля конвейера нет и сейчас — менять не предлагается.

## 4. Деплой и секреты (п. 3)

Остаются в victory (операционный контур хоста):

- корневой `docker-compose.yml`: `news-db`, `conveyor`, `publisher`, профиль
  `conveyor`, тома `newsdb`/`conveyor_*`/`publisher_media`;
- `.env.conveyor`, `.env.publisher` (и `.example`-файлы) — секреты вне git,
  правило не нарушается: в новый репо едут только примеры;
- `services/chat-host-cron/post_news_to_victory.sh`
  — монтируется в `conveyor` как `MIRROR_SCRIPT` (контракт «файл по пути»,
  зафиксированный в SERVICE.md коллектора). Скрипт 1 файл и он принадлежит
  границе двух систем; печь его в образ конвейера нельзя — `services-check`
  роняет ссылку службы на службу. Оставляем в victory, compose-маунт не
  меняется;
- `docs/runbooks/cutover-1.0.md` и история переезда — архив, не трогаем.

Уезжают: исходники коллектора и публикатора, их Dockerfile'ы, `schema/`
(initdb-скрипты news-db — фактически миграции БД конвейера, должны жить
рядом с кодом, который их генерирует; как compose получает к ним доступ
после выноса — развилка 5a/5b раздела 8).

Замечание по монтированию schema: сегодня `news-db` монтирует
`./services/urgent-news-collector/schema` из checkout'а victory, и после
выноса этот путь исчезнет (шаг 6). Источник initdb-скриптов должен остаться
адресуемым — тут развилка вариантов 5a/5b раздела 8: перенацеливание mount
на checkout нового репо либо учётная копия в victory с hash-пином.

## 5. Контракты, которые нельзя ломать (п. 4)

Конвейер живой: пост каждые 15 минут. Независимо от выбранной опции:

1. **`POST /webhooks/news_ingest`** (Rails-сторона, никуда не уезжает):
   payload с `external_id`, `external_source`, `title`, `body_md`,
   `hashtags`, `category`, `schema_type`, `published_at`, `source_url`,
   `telegram_channel_url`, `telegram_channel_handle`; idempotency по
   `external_id`.
   Ответ с `.url` — **баг #189** (внутренний `http://web:3000/...` вместо
   `https://victory62.org/...`): фикс влит в `dev/chat` (#193), до релиза
   в main в постах ссылка останется внутренней. Контроль перед миграцией:
   проверить, что ответ вебхука (или результат #193 после релиза) отдаёт
   публичный `.url`. К выносу отношения не имеет, но точка известная.
2. **`urgent_*.meta.json` / `digest_*.meta.json`** — файловый контракт между
   триггерами коллектора и `MIRROR_SCRIPT` (chat-host-cron). Скрипт
   `services/chat-host-cron/post_news_to_victory.sh` читает из meta-файла
   пять ключей: `event_id`, `headline`, `short_summary`, `hashtags`,
   `source_url`. Два из них — с fallback'ами: `event_id` у digest-пайплайнов
   отсутствует (подстановка имени файла без суффикса — команда
   `basename "$META" .meta.json`), `headline` у digest отсутствует (fallback `short_summary`).
   Поля `external_id` в meta-файле **нет** — оно создаётся
   только в payload вебхука из `event_id`/имени файла (строка 65 скрипта). Поэтому
   список «запрещённых к переименованию» ключей: `event_id`, `headline`,
   `short_summary`, `hashtags`, `source_url`; переименование любого без
   синхронной правки скрипта в victory сломает зеркало молча (пост в TG
   будет, на сайте — нет). Контроль: чек-лист миграции, шаг «первый
   `[news_ingest] OK` в логе».
3. **`posts_queue` / `content_revisions` / `system_flags` / `urgent_events`**
   в `news-db` — коннектор и публикатор связаны только таблицей; схема
   уезжает вместе с кодом (п. 4), том `newsdb` и сами данные — нет. Миграции
   схемы на живой базе — out of scope, при необходимости отдельным issue.
4. **Публикация в @rznvictory** — `publisher` читает `posts_queue`; токен
   бота в `.env.publisher` (утёк 05.10.26, ротация через @BotFather по
   `docs/runbooks/cutover-1.0.md`, окно B) остаётся на хосте,
   `CHANNEL_BOT_TOKEN` в новый репо не копируется. Предусловие шага 5:
   подтверждено, что `/revoke` утёкшего токена выполнен при ротации
   (отметка в cutover-1.0.md); если подтверждения нет — выполнить `/revoke`
   через @BotFather до переключения (getMe этого не докажет: старого токена
   у нас нет). Контроль перед переключением: токен принят Bot API — `curl
   "https://api.telegram.org/bot$(grep -E '^CHANNEL_BOT_TOKEN='
   .env.publisher | cut -d= -f2-)/getMe"` вернул `"ok":true`.
5. **LLM-шлюз omniroute** (chat:20128 по LAN) — адрес и ключи в
   `.env.conveyor`; новый репо их не видит (пример-файл только).

## 6. Владение и учёт (п. 5)

Правила (`services/README.md`, `bin/services-check`) держатся проверкой, не
договорённостью. Без учётного моста конвейер выпадет из реестра при удалении
каталогов — ровно та молчаливая потеря, которую правило «у каждого каталога
есть SERVICE.md» существует, чтобы ловить.

Предлагается минимальный код учёта (отдельным PR после утверждения плана):

- `bin/services-check` получает поддержку необязательного поля frontmatter
  `repo: <url>`: такой каталог — «учётная заглушка внешней службы» —
  `owner: victory` по-прежнему обязателен, `deploy` обязан ссылаться на
  внешний репозиторий, проверка границ (импорты) сохраняется, отсутствие
  кода — не ошибка. Дёшево: ~15 строк python.
- В `services/` остаются **две** учётные заглушки — по одной на выносимую
  службу, чтобы отдельный учёт `content-publisher` не растворился в общей
  «conveyor»:
  - `services/urgent-news-collector/SERVICE.md`: `service:
    urgent-news-collector`, `repo: github.com/nick4man/victory-conveyor`,
    `deploy: образ victory-conveyor, compose-профиль conveyor …; код и CI —
    во внешнем репо`. При варианте 5b (раздел 8) каталог заглушки держит
    ещё и учётную копию `schema/` с пином sha256 в манифесте — `bin/services-check`
    сверяет копию с пином, расхождение с новым репо ловится при обновлении пина;
  - `services/content-publisher/SERVICE.md`: `service: content-publisher`,
    `repo: github.com/nick4man/victory-conveyor`, `deploy: образ
    victory-publisher …; код и CI — во внешнем репо`.
  Обе видны агентам и ревьюерам diff'ов victory; правила «владелец
  victory», «службы не знают друг о друге» не нарушаются — chat-host-cron
  продолжает существовать как полноценная служба с собственным SERVICE.md.
- `services/README.md`: две строки «внешний репо» + абзац про образный
  контракт в раздел «Упаковка».

`VENDOR.md` у audit-engine не трогаем; его репатриация — отдельный трек.

## 7. Легаси на хосте chat (п. 6)

Два наследия, их надо различать:

- `/opt/.openclaw/.openclaw/workspace-conveyor` — openclaw-архив, **только
  чтение** (запрет продублирован в `.claude/settings.json`). Боевого
  конвейера там нет с 11.09.26, но **cron-строки на chat всё ещё читают
  архивные скрипты** — по `SERVICE.md` коллектора (раздел «Соседи по
  архиву»): `backfill_embeddings.py`, `weekly_infra_check.py`,
  `ingest_macro_economics.py`, `ingest_posts_queue.py`,
  `gemini_embedding_writer.py`, `auto_assembly_trigger.py`,
  `test_digest_resilience.py`. Это не «живого трафика нет», это «пишущего
  трафика нет». Удаление архива для закрытия п. 6 #190 не требуется
  (отдельное решение владельца, открытый вопрос 4 раздела 9), но финальная
  архивация возможна только после инвентаризации и отключения этих
  cron-потребителей — предусловие шага 7.
- `/opt/victory-conveyor` на chat — бывший боевой каталог (cutover B,
  13.10.26: крон заморожен, `publisher-bot` остановлен). По cutover-1.0.md
  он должен был остаться «до ротации пароля audit_user», которую читают
  агенты openclaw. В план миграции добавляется финальный шаг: после N дней
  стабильной работы конвейера из нового репо — инвентаризация
  `audit_user`-потребителей и удаление каталога (это разблокирует и
  ротацию пароля). До этого шага вынос конвейера на chat ничего не меняет.

Итог по п. 6 #190: закрывается инвентарной записью об openclaw-архиве с
его cron-потребителями (архив никуда не девается) и финализацией
`/opt/victory-conveyor` (шаг 7 — про него, не про openclaw-архив).

## 8. План миграции (точки отката; про «нулевой простой» — ниже)

Все шаги — без остановки текущего конвейера; переключение — перекатка
служб конвейера в окне между тиками (как cutover B).

**Развилка: критерий «без простоя» (#190) — два варианта шага 5.**
Критерий issue — «без простоя конвейера». Смена mount у `news-db`
(перенацеливание источника схемы) пересоздаёт её контейнер — секунды
недоступности БД. Поэтому два варианта:

- **5a — единое окно.** mount перенацеливается на checkout нового репо
  (шаг 4); `news-db`, `conveyor`, `publisher` перекатываются одной
  командой в окне между тиками. Недоступность БД — секунды; посты **не
  теряются**: `posts_queue` и state — в именованных томах, пропущенный тик
  подбирается следующим прогоном. Единый источник схемы, без дублей.
- **5b — строгий ноль.** mount `news-db` не меняется, контейнер не
  пересоздаётся, перекатываются только `conveyor` и `publisher`. В stub
  `services/urgent-news-collector/schema/` (раздел 6) кладётся учётная
  копия initdb-скриптов с пином sha256 в манифесте — `bin/services-check`
  сверяет копию с пином; расхождение с новым репо ловится при обновлении
  пина отдельным коммитом victory. Цена: двойной источник схемы.

Выбор варианта — открытый вопрос 5 (раздел 9); команды шага 5 ниже — для
5a, для 5b те же без `news-db` и без правок mount в шаге 4.

**Шаг 0. Утверждение (человек).** Владелец выбирает опцию и вариант 5a/5b.
До утверждения issue #190 не закрывается, код не двигается.

**Шаг 1. Создание репозитория `nick4man/victory-conveyor`.**
`git filter-repo`/subtree-split истории каталогов коллектора и публикатора
с сохранением коммитов; layout внутри: `urgent-news-collector/`,
`content-publisher/`, `README.md`, `VERSION`, `.github/workflows/`
(tests + build/push образов).
*Откат: удалить репо, ничего не произошло.*

**Шаг 2. CI нового репо и доступ к GHCR.** Workflow: `unittest`
(существующие тесты), сборка+пуш `victory-conveyor:sha-*` и
`victory-publisher:sha-*` на merge. Образы продолжают лежать по тем же
путям `ghcr.io/nick4man/victory-{conveyor,publisher}` — compose и rollout
не меняются. Механика доступа: пакеты принадлежат `nick4man/victory`, а
`GITHUB_TOKEN` Actions нового репо в чужой пакет пушить не может. Два
рабочих варианта (выбрать до первого пуша, применить к **обоим** пакетам):
- **Actions access к пакету** (рекомендуется, без долгоживущего PAT):
  настройки пакета на GHCR → «Manage Actions access» → Add repository →
  `nick4man/victory-conveyor` → роль **Write**; после этого `GITHUB_TOKEN`
  нового репо с permission `packages: write` пушит в пакет. Простого
  «Connect repository» (ссылка на странице репо) недостаточно — права
  на push выдаются именно через Manage Actions access.
- PAT с scope `write:packages` в секрете `GHCR_PAT` нового репо.
*Откат: workflow выключается одним коммитом.*

**Шаг 3. Первая сборка из нового репо.** Получаем тег, например
`sha-<7>` (или `<VERSION>` конвейера). Проверка образа: `docker run --rm
ghcr.io/nick4man/victory-conveyor:<tag> python3 -m unittest discover` —
тесты внутри образа зелёные. Плюс проверка канала поставки **до** шага 4 —
**оба** образа, с фиксацией image ID (иначе возможен запуск прежнего кода
под новым тегом):

```bash
for img in victory-conveyor victory-publisher; do
  docker pull ghcr.io/nick4man/$img:<tag>
  # digest реестра и digest того, что реально лежит локально после pull:
  echo "$img реестр:    $(docker buildx imagetools inspect ghcr.io/nick4man/$img:<tag> --format '{{.Manifest.Digest}}')"
  echo "$img локально:  $(docker image inspect ghcr.io/nick4man/$img:<tag> --format '{{index .RepoDigests 0}}')"
  docker image inspect ghcr.io/nick4man/$img:<tag> --format '{{.Created}}'
done
```

Сверить локальный `RepoDigests` с digest реестра — совпадение гарантирует,
что под тегом лежит именно тот образ, а не прежний код под свежим тегом.
Provenance: digest реестра сверяем не «сам с собой», а с digest'ом workflow'а
нового репо для **конкретного** run'а сборки (build/push печатает digest в
лог; run URL и оба digest фиксируем в чек-листе миграции), `Created` — со
временем сборки того же run'а. Локальный config ID (`docker image inspect
{{.Id}}`) с manifest digest сверять нельзя — разные хеши.
*Откат: образ просто не используется.*

**Шаг 4. Подготовка victory (PR в dev/upgrade, отдельный issue после
утверждения):** build.yml теряет conveyor/publisher из матрицы; compose:
**секции `build:` у `conveyor` и `publisher` удаляются** — службы становятся
чистыми registry-образами, и `compose pull --ignore-buildable` в `bin/rollout`
перестаёт их пропускать (сейчас buildable-службы rollout не пуллит, а при
исчезнувшем после шага 6 build-context упал бы на `compose build`); mount
schema — по выбранному варианту: 5a — перенацелить на checkout нового репо
(`/home/q/victory-conveyor/urgent-news-collector/schema`), 5b — оставить как
есть и добавить учётную копию с hash-пином в stub (раздел 6);
`bin/services-check` — поддержка `repo:`; учётные заглушки
`services/urgent-news-collector/` и `services/content-publisher/` (раздел
6); `services/README.md` — строки учёта. Рабочий код конвейера из victory
**не удаляется в этом PR** — только публикация новых образов останавливается
(это и есть точка невозврата вперёд). *Откат: revert PR, матрица
возвращается.*

Доставка compose на хост: `bin/rollout` запускается из ops-каталога
`/home/q/victory` (checkout main на хосте; bind-mount отключён с cutover 1.0),
поэтому до шага 5 там обязателен `git -C /home/q/victory pull` — иначе
rollout пойдёт по старому compose (fail-fast — в шаге 5).

Checkout нового репо на хосте (вариант 5a; для 5b checkout не нужен, а
initdb-смок ниже гоняется против учётной копии в stub) — с дисциплиной
синхронизации, без неё initdb-схема и код образа разойдутся молча:
- `git clone https://github.com/nick4man/victory-conveyor /home/q/victory-conveyor`
  (ops-каталог рядом с `/home/q/victory`, вне victory);
- checkout строго по immutable-ревизии, совпадающей с тегом образа: для
  тега `sha-<7>` это `git -C /home/q/victory-conveyor fetch && git -C
  /home/q/victory-conveyor checkout <sha>`; для `<VERSION>` — тег в новом
  репо, указывающий на тот же sha;
- контроль после checkout: `git -C /home/q/victory-conveyor rev-parse HEAD`
  равен sha тега. Дальше — **initdb-смок на scratch-томе** (не на боевом
  `newsdb`; образ тот же, что у news-db — `viktory-postgres-pgvector:
  pg15-postgis36`, схема требует pgvector):

  ```bash
  docker rm -f newsdb-smoke 2>/dev/null || true
  docker volume rm -f smoke_initdb 2>/dev/null || true  # повторный том пропустил бы initdb
  trap 'docker rm -f newsdb-smoke 2>/dev/null; docker volume rm -f smoke_initdb 2>/dev/null' EXIT
  docker volume create smoke_initdb
  docker run -d --name newsdb-smoke \
    -e POSTGRES_PASSWORD=smoke -e POSTGRES_USER=news -e POSTGRES_DB=news \
    -v /home/q/victory-conveyor/urgent-news-collector/schema:/docker-entrypoint-initdb.d:ro \
    -v smoke_initdb:/var/lib/postgresql/data viktory-postgres-pgvector:pg15-postgis36
  # pg_isready отвечает уже на ВРЕМЕННЫЙ initdb-сервер (техника из bin/backup) —
  # ждём в логах завершения инициализации, потом постоянный сервер:
  for i in $(seq 1 90); do
    docker logs newsdb-smoke 2>&1 | grep -q 'init process complete' && break
    [ "$i" = 90 ] && { echo 'initdb не завершился за 90 с' >&2; exit 1; }
    sleep 1
  done
  for i in $(seq 1 30); do
    docker exec newsdb-smoke pg_isready -U news -d news -q 2>/dev/null && break
    [ "$i" = 30 ] && { echo 'постоянный сервер не поднялся за 30 с' >&2; exit 1; }
    sleep 1
  done
  # initdb применился: ровно четыре таблицы (не "хотя бы одна"):
  count=$(docker exec newsdb-smoke psql -U news -d news -tAc \
    "select count(*) from information_schema.tables where table_schema='public'
     and table_name in ('urgent_events','posts_queue','content_revisions','system_flags')")
  [ "$count" = "4" ] || { echo "таблиц $count вместо 4 — initdb-смок провален" >&2; exit 1; }
  docker rm -f newsdb-smoke && docker volume rm smoke_initdb && trap - EXIT
  ```

  Простой `ls` mount'а этого не проверяет: ошибки initdb-скриптов видны
  только на пустом томе;
- обновление checkout — часть той же процедуры, что и смена `CONVEYOR_TAG`
  (следующий шаг): сначала checkout по sha, потом override в `.env.deploy`,
  одним окном; откат шага 5 возвращает и checkout (`git -C
  /home/q/victory-conveyor checkout <прежний sha>`).

**Шаг 5. Переключение прода на образ из нового репо** (команды — для
5a; для 5b пропустить проверку mount и checkout и убрать `news-db` из
п. 3).
В окне между тиками, механика — per-service override из `release.md`, не
shell-prefix (иначе следующая выкатка Rails увезёт конвейер на общий тег).
Перед переключением зафиксировать прежние теги (`PREV_CONVEYOR_TAG`,
`PREV_PUBLISHER_TAG` из `.env.deploy`) — откат без них невозможен.

```bash
cd /home/q/victory   # rollout и .env.deploy живут в ops-каталоге
# 0) доставка compose шага 4 + fail-fast:
git -C /home/q/victory pull --ff-only
[ "$(git -C /home/q/victory rev-parse HEAD)" = \
  "$(git ls-remote https://github.com/nick4man/victory main | cut -f1)" ] \
  || { echo 'ops-каталог не на актуальном main' >&2; exit 1; }
docker compose --profile conveyor config | grep -q '/home/q/victory-conveyor/urgent-news-collector/schema' \
  || { echo 'compose не содержит нового mount schema' >&2; exit 1; }
# старые build:-секции должны быть удалены:
docker compose --profile conveyor config \
  | grep -E 'context: .*/services/(urgent-news-collector|content-publisher)' \
  && { echo 'build:-секции conveyor/publisher не удалены' >&2; exit 1; }
# 1) checkout нового репо по sha тега (дисциплина из шага 4; 5a)
git -C /home/q/victory-conveyor fetch && git -C /home/q/victory-conveyor checkout <sha>
# 2) фиксируем override в .env.deploy — как в docs/runbooks/release.md
{ grep -vE '^(CONVEYOR_TAG|PUBLISHER_TAG)=' .env.deploy || true; } > .env.deploy.new
printf 'CONVEYOR_TAG=%s\nPUBLISHER_TAG=%s\n' "<tag>" "<tag>" >> .env.deploy.new
mv .env.deploy.new .env.deploy
# 3) одна перекатка: news-db (пересоздание из-за смены mount, данные в томе)
#    + conveyor + publisher
bin/rollout "$(grep -E '^VICTORY_TAG=' .env.deploy | cut -d= -f2-)" \
  --services news-db,conveyor,publisher --profile conveyor --skip-backup
```

Контроль 30–60 мин: тики supercronic, в логах conveyor `grep -ciE
'error|traceback'` → 0, у publisher `Telegram Bot started`, строка
`[news_ingest] OK` после первого триггера, новая запись на `/news`.
*Откат (минуты): вернуть в `.env.deploy` **зафиксированные** `PREV_CONVEYOR_TAG`
/ `PREV_PUBLISHER_TAG` (не удалять строки: после шага 4 victory больше не
публикует образы конвейера под общим `VICTORY_TAG` — без override pull
пойдёт за несуществующим тегом) и повторить команду п. 3; в 5a дополнительно
вернуть checkout (`git -C /home/q/victory-conveyor checkout <прежний sha>`).
Mount schema обратно не откатываем (на существующем томе `newsdb` initdb
не повторяется, данные не трогаются); данные в общем томе, ничего не теряется.*

**Шаг 6. Удаление кода из victory (PR, через 5–7 дней стабильной работы).**
Код удаляется, **учётные манифесты-заглушки остаются**: `git rm -r
services/urgent-news-collector services/content-publisher`, затем возврат
двух SERVICE.md из истории (`git checkout <коммит шага 4> --
services/urgent-news-collector/SERVICE.md
services/content-publisher/SERVICE.md`). Остающиеся ссылки — CLAUDE.md-
соседи, AGENTS.md, repo-index. CI victory зелёный. *Откат: revert PR;
история с кодом остаётся в git навсегда.*

**Шаг 7. Финализация chat-легаси.** Предусловие: инвентаризированы и
отключены cron-потребители openclaw-архива (`backfill_embeddings.py` и др.
из SERVICE.md коллектора, раздел 7) — иначе на chat останутся крон-строки,
читающие архивные пути. Далее: инвентаризация читателей
`audit_user@postgres-local`, ротация пароля. Перед удалением
`/opt/victory-conveyor` — снапшот, **зашифрованный** (внутри каталога лежит
`.env` с секретами — открытый tar на том же хосте недопустим) и проверенный
тестовым восстановлением:

```bash
( umask 077
  tar -C /opt -czf - victory-conveyor | gpg -c -o /var/backups/victory-conveyor-09.11.26.tar.gz.gpg
  chmod 600 /var/backups/victory-conveyor-09.11.26.tar.gz.gpg )
# off-host: копия в backup-контур chat (назначение — из конфигурации бэкапов
# хоста), сверка по sha256 — иначе единственный архив остаётся на удаляемом хосте:
rsync -a /var/backups/victory-conveyor-09.11.26.tar.gz.gpg <backup-host>:/backups/chat/
ssh <backup-host> sha256sum /backups/chat/victory-conveyor-09.11.26.tar.gz.gpg
sha256sum /var/backups/victory-conveyor-09.11.26.tar.gz.gpg   # хеши совпали
# проверка восстановления, а не только чтения оглавления:
( umask 077; mkdir -p /tmp/restore-check )
gpg -d /var/backups/victory-conveyor-09.11.26.tar.gz.gpg | tar -xz -C /tmp/restore-check
# побайтовая сверка содержимого (имена не ловят повреждение .env и state):
diff -r /opt/victory-conveyor /tmp/restore-check/victory-conveyor \
  && echo 'содержимое совпало побайтово'
rm -rf /tmp/restore-check   # cleanup: в /tmp не остаётся распакованных секретов
```

Путь `/var/backups` — вне удаляемого дерева (конкретный каталог — по месту).
Содержимое совпало — только после этого `rm -rf /opt/victory-conveyor`;
запись в cutover-1.0.md/этот документ.
*Откат: распаковать снапшот обратно (`gpg -d … | tar -xz -C /opt`); данные
на chat конвейеру не нужны (он на victory) — восстанавливаем каталог ради
cron/state-остатков и audit-следов.*

**Оценка рисков.** Критический путь — шаг 5: перекатка в окне между
тиками, механика отработана в release.md; схема БД и данные не трогаются;
единственная недоступность — секунды рестарта `news-db` (в 5b её нет);
откат — минуты, без восстановления данных. Главный организационный риск —
двойная правка (код в двух репо между шагами 3 и 6): любой merge в
`services/urgent-news-collector` и `services/content-publisher` заморожен
с шага 3 до шага 6.

## 9. Открытые вопросы владельцу

1. Опция: E (рекомендация) / D / A (остаться)? B и C — обоснование в разделе 2.
2. Частота релизов конвейера: при редких коротких правках разумнее A —
   вынос окупается при желании катить конвейер независимо от Rails.
3. Имя репо: `nick4man/victory-conveyor`? (образы уже `victory-conveyor` —
   совпадение имён упростит учёт.)
4. Удалять ли openclaw-архив `/opt/.openclaw/.openclaw/workspace-conveyor`
   на chat или оставить как исторический архив (отдельное решение; при
   удалении — только после отключения его cron-потребителей, раздел 7).
5. Критерий «без простоя» (раздел 8): вариант **5b** (строгий ноль, двойной
   источник схемы с hash-пином) или **5a** (единое окно, секунды рестарта
   `news-db`, единый источник схемы)?
