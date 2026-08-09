# Зелёный rspec + rspec в CI-gate

## Context

После появления `bin/rb` сьют наконец запускается из любой сессии: **895 examples, 29 failures**.

Это **не регрессии Rails 8.1**. В PR #5 (эпоха Rails 7.2) было «895/34» при том же числе примеров —
то есть перед нами накопленный долг спеков, один настоящий дефект и одна инфраструктурная мина.
Пока сьют красный, включить `rspec` в CI-gate нельзя, а раз он не в gate — долг растёт дальше.
Цель: 895/0 и `rspec` в обязательных проверках PR.

**Решения приняты пользователем:** `now` протягиваем в модель; `null_store` обходим точечно в спеке;
чиним все 29 и сразу включаем rspec в CI.

---

## Разбор 29 падений по корневым причинам

### Группа 1 — тесты ходят в реальный интернет (2 падения + флакость всего сьюта)

`spec/rails_helper.rb:29` — `WebMock.allow_net_connect!`. Property-спеки падают с
`OpenSSL::SSL::SSLError` на `151.101.1.91:443`. Источники сетевых вызовов: гем `geocoder`
(`Gemfile:89`) по `address`, плюс `after_commit` хуки `notify_indexnow_on_publish` и
`notify_yandex_recrawl_on_publish` (`app/models/property.rb:251,257`).

Это не «2 падения», а недетерминированность всего прогона: любой спек может ткнуться во внешний
сервис и упасть по чужой недоступности. **Чинить первым** — иначе остальные цифры невоспроизводимы.

### Группа 2 — настоящий дефект: `now:` протянут наполовину (4 падения)

`DocumentChecklist::SlaAssessor.assess(dr, now:)` использует `@now` для weekend-проверки и
rewindow-cooldown (`sla_assessor.rb:61,103,109`), но `overdue_factor` берёт из модели, где
жёстко `Time.current` (`app/models/document_requirement.rb:184`).

Спек фиксирует `now: 19.05.26`; реальное время ушло на ~81 день, фактор считается по настоящим
часам → всегда tier 3 вместо 1/2/nil. В проде безвредно (`now ≈ Time.current`), но параметр
обманывает вызывающего: backfill, replay или симуляция получат неверный tier молча.

### Группа 3 — verified doubles отстали от кода (5 падений)

`spec/jobs/document_intake/parser_job_spec.rb`: `InstanceDouble(ClientDocument)` не стабит
`property` и `nextcloud_path`, которые код начал звать
(`app/services/document_intake/nextcloud_mirror.rb:80`, `app/jobs/document_intake/parser_job.rb:29`).
Верифицирующий двойник отработал ровно как задумано — это механическая доработка стабов.

### Группа 4 — конфиг ушёл вперёд спеков (4 падения, TopicRegistry)

- `missing_keys` ждёт 16, получает 0: в `config/telegram_topics.yml` теперь 18 заполненных
  `message_thread_id` — топики discovered, «недостающих» честно нет. Спек фиксировал состояние
  до discovery.
- `record_discovery` → `thread_id` возвращает 17 вместо 42: `config.cache_store = :null_store`
  (`config/environments/test.rb:30`) делает запись в кэш no-op, `overrides` всегда пуст и
  побеждает значение из YAML.
- `auto_route_for('site_valuation_form')` → nil: канонический источник везде `site_valuation`
  (`app/models/lead_event.rb:14`, `app/services/lead/intake.rb:21`), значения `site_valuation_form`
  не существует нигде. **Спек выдумал источник** — код и YAML правы.

### Группа 5 — тексты и поведение изменились (9 падений)

`WeeklySummaryJob` («Недельный отчёт» → «📊 Сводка за неделю»), `CheatsheetRenderer` ×2,
`Kpi::MorningDigest` ×4, `Commands::Dashboard` (ответ в исходный чат `500001`, спек ждёт DM `500002`),
`LeadEvent#anchor_url` (строит ссылку без thread_id, спек ждёт nil).

По каждому решаем «код прав / спек прав». Большинство — спек. **Исключение:** MorningDigest
отдаёт «Вчера: данных пока нет», хотя спек создал `StaffMetric` — здесь сначала выясняем, почему
lookup не находит запись; это может оказаться реальным багом, а не устаревшим ожиданием.

### Группа 6 — фикстуры против новых ограничений (5 падений)

- `builder_spec.rb:33` — `update_columns(lead_ref_type: nil)` против NOT NULL на
  `lead_events.lead_ref_type`. Сценарий стал невозможен на уровне схемы. Ветка `default_sale`
  (`app/services/document_checklist/builder.rb:102`) **не мертва** — достижима, когда
  `lead_ref` разрешается в nil или тип не найден в `TemplateRegistry`; переписать спек на
  достижимый путь.
- `builder_spec.rb:154` — `Inquiry.create!(name: 'R')` → «Name Слишком короткое», валидация
  добавлена позже фикстуры.
- `TelegramGroupMessage` uniqueness, `InnParser` full_name, `Property` enums `be_rent`.

---

## Порядок работ

**Шаг 0 — сетевая изоляция (обязательно первым).**
`WebMock.disable_net_connect!(allow_localhost: true)` в `spec/rails_helper.rb`. Дальше по факту
падений: отключить geocoding в test (`Geocoder.configure(lookup: :test)` + stub), заглушить
IndexNow/Yandex-хуки Property. Ожидаемо вскроет спеки, которые молча ходили в сеть и «проходили» —
их считаем частью работы.

**Шаг 1 — дефект `now:`.** `time_since_requested(now: Time.current)` и `overdue_factor(now: Time.current)`
в `document_requirement.rb`, вызов `@dr.overdue_factor(now: @now)` в `sla_assessor.rb:65`.
Проверить остальных вызывающих `overdue_factor`/`overdue?` — сигнатура с дефолтом обратно совместима.
Спеки становятся детерминированными без `travel_to`.

**Шаг 2 — механические группы 3, 4, 6.** Дополнить стабы; обновить ожидания TopicRegistry
(`missing_keys` → 0, источник `site_valuation`); `:memory_store` подменить точечно в
`topic_registry_spec.rb` (не трогая `test.rb` — остальные 895 примеров сохраняют семантику);
починить фикстуры под актуальные валидации и NOT NULL.

**Шаг 3 — группа 5, по одному.** Для MorningDigest сначала диагностика lookup'а `StaffMetric`.

**Шаг 4 — CI-gate.** Новая job `rspec` в `.github/workflows/lint.yml`.

Две вещи, которые обязательно всплывут:

- **БД.** Нужны `postgis`, `vector`, `pg_trgm`, `unaccent` (`db/structure.sql:16-58`). Ни один
  публичный образ не несёт postgis и pgvector одновременно, поэтому `services:` не подойдёт —
  собираем `Dockerfile.postgres` прямо в job и запускаем `docker run` с healthcheck. Сам rspec
  гоняем нативно через `ruby/setup-ruby` (как три существующие job), а не через `bin/rb`:
  так CI не зависит от compose-файла.
- **`DATABASE_URL` обязателен.** `config/database.yml:102` (блок `staging`) делает
  `ENV.fetch("DATABASE_URL")` без дефолта, а ERB рендерит весь файл на любой среде — без
  переменной падает `KeyError` ещё до выбора секции. Ровно на это я наткнулся при настройке
  `bin/rb`. Правильный фикс — `ENV.fetch("DATABASE_URL", nil)` в database.yml: убирает мину
  для всех окружений разом.

Ещё: `config.eager_load = ENV['CI'].present?` (`config/environments/test.rb:19`) — в CI грузится
всё приложение, что может вскрыть load-ошибки, невидимые локально. Первый CI-прогон может дать
больше 29 падений; это ожидаемо и входит в работу. Заодно поправить устаревший комментарий
«Gemfile (ruby '3.2.2')` в `lint.yml` — там давно 3.3.6.

---

## Файлы

| Файл | Что |
|---|---|
| `spec/rails_helper.rb` | `disable_net_connect!`, Geocoder test-lookup |
| `app/models/document_requirement.rb` | `time_since_requested(now:)`, `overdue_factor(now:)` |
| `app/services/document_checklist/sla_assessor.rb` | передать `@now` в фактор |
| `config/database.yml` | `ENV.fetch('DATABASE_URL', nil)` в staging-блоке |
| `.github/workflows/lint.yml` | job `rspec` + сборка `Dockerfile.postgres` |
| `spec/jobs/document_intake/parser_job_spec.rb` | стабы `property`, `nextcloud_path` |
| `spec/services/telegram/topic_registry_spec.rb` | ожидания + точечный `:memory_store` |
| `spec/services/document_checklist/{builder,sla_assessor}_spec.rb` | фикстуры |
| ещё 6 spec-файлов | группы 5 и 6 |

---

## Проверка

```bash
cd /home/q/victory-upgrade

# 1. Сетевой изоляции достаточно — сьют не ходит наружу.
#    Отключить сеть у контейнера и убедиться, что результат тот же:
bin/rb --db 'bundle exec rspec --no-color 2>&1 | tail -3'

# 2. Дефект now: починен — фактор считается от переданного времени
bin/rb --db "bin/rails runner \"
  dr = DocumentRequirement.new(kind: 'passport_main', requested_at: 36.hours.ago)
  puts dr.overdue_factor(now: Time.current).round(2)          # ~1.5
  puts dr.overdue_factor(now: dr.requested_at + 12.hours).round(2)  # 0.5
\""

# 3. Полный прогон — цель
bin/rb --db 'bundle exec rspec --no-color 2>&1 | grep -E "^[0-9]+ examples"'
#    → 895 examples, 0 failures

# 4. Детерминированность: два прогона с разными seed дают одно и то же
for s in 111 222; do bin/rb --db "bundle exec rspec --no-color --seed $s 2>&1 | grep -E '^[0-9]+ examples'"; done

# 5. eager_load, как в CI (может вскрыть load-ошибки)
bin/rb --db 'CI=1 bundle exec rspec --no-color 2>&1 | grep -E "^[0-9]+ examples"'

# 6. Ничего не сломали в остальном
bin/rb bundle exec rubocop --parallel
bin/rb bundle exec brakeman --exit-on-warn --quiet --format text

# 7. CI — проверяется на PR: job `rspec` должен стать обязательным вместе с
#    rubocop / brakeman / bundler-audit
```

---

## Риски

**Шаг 0 вскроет больше падений, чем 29.** Спеки, которые молча ходили в сеть и «проходили» на
живых ответах, станут красными. Это не регресс, а обнажение уже существующей проблемы — но объём
работы может вырасти. Если вылезет много, разумно остановиться и пересогласовать.

**Правка `overdue_factor` трогает прод-код.** Дефолт `now: Time.current` сохраняет поведение всех
текущих вызывающих; риск низкий, но перед мержем нужен прогон `document_checklist` целиком.

**CI-job с docker build постгреса медленный** (сборка образа на каждый прогон). Если станет
узким местом — кэшировать через GHCR отдельным шагом.
