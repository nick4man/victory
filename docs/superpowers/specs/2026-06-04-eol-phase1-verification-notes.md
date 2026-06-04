# EOL Phase 1 — Rails 7.2.3.1 deps-layer verification notes (04.06.26)

> Дополнение к `2026-06-04-eol-rails-ruby-upgrade-design.md`. Фиксирует результаты
> локальной verification deps-layer апгрейда (commit `14e3c1d` + structure.sql).

## Что verified (disposable container `victory-web:eol-test`, прод не тронут)

| Проверка | Результат |
|---|---|
| Gems resolve + build (`docker build`) | ✅ image 1.38 GB |
| App boots Rails 7.2.3.1 + Ruby 3.2.2 (`rails runner`) | ✅ BOOT_OK, все initializers |
| bundler-audit (новый Gemfile.lock) | ✅ GREEN (0 vuln, devise documented-ignore) |
| Migration API на 7.2 (`db:migrate` from scratch) | ✅ 72 migrations + остальные после structure.sql |
| `maintain_test_schema!` (structure.sql) | ✅ passes (rebuild-дыра закрыта) |
| Full spec suite (843 examples) | ⚠️ 742 pass / 101 fail — **ВСЕ 101 pre-existing test-debt, 0 Rails-7.2 regressions** |

## Spec failures breakdown (101) — НЕ Rails 7.2

| Класс | Кол-во | Корень | Версия-зависимо? |
|---|---|---|---|
| `PG::NotNullViolation` + `ActiveRecord::NotNullViolation` | 90+45 | factories не заполняют NOT-NULL колонки текущей схемы (factory drift) | НЕТ |
| `ActiveRecord::RecordInvalid` | 29 | validation failures (тот же data/factory корень) | НЕТ |
| `NoMethodError: undefined method 'stub_request'` | 7 | WebMock не require'ится/конфигурится в test env (yandex_vision/client_spec) | НЕТ |
| assertion mismatch (e.g. WeeklySummaryJob ждёт «Недельный отчёт», код шлёт «Сводка за неделю») | остаток | stale spec text vs текущий код (code drift) | НЕТ |

**Вывод**: ни одна failure не вызвана Rails 7.2 (нет removed-API NoMethodError, нет
deprecation-turned-error, нет load errors). Baseline test-suite был НЕ зелёным и на
7.1 — это ровно то, что EOL design **Layer 0** («specs → ~green ПЕРЕД upgrade») должен
исправить. Rails 7.2.3.1 сам по себе звучен.

## Найдено + исправлено: schema-rebuild дыра

`db/migrate/` не содержит `create_client_documents`, а `20260527000900_add_nextcloud_to_client_documents`
делает `change_table(:client_documents)`. С чистой БД migrate падает (`relation does not
exist`). structure.sql не был закоммичен → `db:schema:load` тоже невозможен. **Прод
«работал» только потому что БД строилась инкрементально.**

**Fix (этот commit)**: `db/structure.sql` сгенерирован из живой dev-БД (`db:schema:dump`,
read-only) и закоммичен. Теперь `db:schema:load` восстанавливает схему с нуля → staging/CI
могут поднять чистое окружение. (schema_format = :sql, см. application.rb:113.)

## Известные Phase-2 указатели

- `enum :role, {...}` keyword-args deprecated → Rails 8.0 (positional). ~N моделей.
  Deprecation, НЕ 7.2-блокер. Конвертация — Phase 2.
- WebMock test-config gap (stub_request) — добавить `require 'webmock/rspec'` в
  rails_helper при Layer 0 spec-фиксе.
- Factory NOT-NULL drift — обновить factories под текущую схему (Layer 0).

## НЕ сделано (staging-layer работа)

- Ruby 3.2.2 → 3.3.6 (Dockerfile base, закрывает Brakeman EOLRuby)
- `config.load_defaults 7.2` flip + `bin/rails app:update` (Step 2b)
- Layer 0 spec cleanup (101 failures → 0)
- ransack 4.4 / neighbor 0.6 runtime smoke (nearest_neighbors, admin search)
- Staging deploy + 3-day acceptance + prod 24h watch (Section 7-8)
