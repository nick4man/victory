# План: хардненинг `Topnlab::Client#get_ids` — закрыть остаточную дыру catalog-wipe

## Context (зачем)

Инцидент «0 объектов в каталоге victory62.org» был вызван тем, что при неудачном sweep
Topnlab-импортёр видел пустой `seen_ids` и архивировал весь активный каталог
(`archive_missing`). **PR #6** (уже в проде) закрыл случай, когда `get_ids` **бросает**
исключение (network/auth/timeout): такой сегмент теперь инкрементит `fetch_errors`, и
`archive_missing` пропускается при `fetch_errors.positive?`.

Осталась **вторая дверь в ту же комнату**: `get_ids` НЕ бросает, когда Topnlab отвечает
`HTTP 200` с телом-не-массивом (`{"status":"error"}`, `{}`, `null`, 404→`nil`). Сейчас:

```ruby
# app/services/topnlab/client.rb:37-38
data = http_get('/get-ids', params, throttle: :slow)
data.is_a?(Array) ? data : []          # ← молча превращает мусор в «пусто»
```

Такой ответ неотличим от легитимно пустой выгрузки. Если Topnlab по всем 12 сегментам
(2 action × 6 realty_type) вернёт error-shaped 200, то `seen_ids` пуст, `fetch_errors == 0`,
guard PR #6 **не срабатывает** → `archive_missing(∅)` снова обнуляет каталог.

**Цель:** считать не-массивный ответ `get-ids` ошибкой fetch, а не пустой выгрузкой, —
чтобы он шёл через уже существующую машинерию PR #6 (`fetch_errors` → archive skip).

## Подход (рекомендуемый)

Бросать `Topnlab::Client::Error` из `get_ids`, когда ответ — не `Array`. Это переиспользует
существующий `rescue StandardError` в `importer.rb:87` (→ `fetch_errors += 1` → archive
пропускается). **Легитимно пустой** `[]` остаётся валидным и НЕ бросает.

### Почему это безопасно для остальных вызовов get_ids

Проверены все 3 caller'а — оба не-importer уже ловят `Topnlab::Client::Error` и деградируют
ровно как сегодня (сейчас non-array→`[]`; после — raise→catch→`[]`/`0`, идентичный исход):

- `orders_importer.rb:58` `safe_get_ids` — `rescue Topnlab::Client::Error → []`. Без изменений.
- `stats_client.rb:102` `safe_count` — `rescue StandardError → 0`. Без изменений.
- `importer.rb:71` — единственный, чьё поведение меняется, и именно как надо: raise → `fetch_errors` → archive skip.

## Изменения

### 1. `app/services/topnlab/client.rb` — `get_ids` (строки 31–39)

Заменить `data.is_a?(Array) ? data : []` на явную проверку с raise:

```ruby
data = http_get('/get-ids', params, throttle: :slow)
unless data.is_a?(Array)
  raise Error,
        "get-ids вернул не-массив (#{data.class}) — трактуем как fetch failure, " \
        "не как пустую выгрузку (защита каталога от ложного archive): " \
        "#{data.inspect.truncate(200)}"
end
data
```

Контракт get-ids по докстрингу — `@return [Array<Integer>]` (bare array; пусто = `[]`),
поэтому Hash/nil = malformed. Обновить комментарий метода, отметив, что не-массив теперь
бросает (сознательно, для fail-safe архивации).

### 2. Регресс-специи (новый файл `spec/services/topnlab/client_spec.rb`)

Специй на `client.rb`/`importer.rb` сейчас НЕТ — этот путь катастрофичен и должен быть покрыт.
webmock 3.26 уже в проекте (`stub_request`), harness — `require 'rails_helper'`.

`Topnlab::Client#get_ids` (stub через webmock на `<base>/get-ids`):
- `200` + JSON-массив `[1,2,3]` → возвращает `[1,2,3]`.
- `200` + пустой массив `[]` → возвращает `[]`, **НЕ бросает** (легитимно пусто).
- `200` + `{"status":"error"}` → **бросает** `Topnlab::Client::Error`.
- `200` + `null` → **бросает**.
- `404` → **бросает** (parse→nil→non-array).

### 3. Регресс-спек на importer (новый `spec/services/topnlab/importer_spec.rb`, целевой кейс)

Главный тест всего инцидента — «malformed get-ids каталог не обнуляет»:
- Мок `client` (instance_double `Topnlab::Client`), где `get_ids` бросает `Topnlab::Client::Error`
  на всех сегментах; в БД есть активные `Property(external_source:'topnlab')`.
- Ожидаем: `call_inner` вернул `fetch_errors > 0`, `archived == 0`, и активные Property
  **остались active** (`archive_missing` не вызывался).
- Контрольный позитив: когда `get_ids` возвращает валидные ids и один объект пропал из
  выгрузки — он архивируется (проверяем, что guard не «сломал» нормальную архивацию).

## Verification

```bash
cd /home/q/victory-victory
bundle exec rspec spec/services/topnlab/client_spec.rb spec/services/topnlab/importer_spec.rb
bundle exec rubocop app/services/topnlab/client.rb spec/services/topnlab/client_spec.rb spec/services/topnlab/importer_spec.rb
```

- Все новые специи зелёные; rubocop чист.
- Ручная провокация (dev-консоль, опц.): застабить get-ids на `{"status":"error"}` →
  `Topnlab::Importer.new.call` → в summary `fetch_errors == 12`, `archived == 0`, лог
  `sweep incomplete, skipping archive_missing`.

## Delivery

1. Ветка `fix/topnlab-get-ids-nonarray-guard` от свежего `main`.
2. Commit (dd.MM.yy в сообщении при датах).
3. **`pr-review-toolkit:code-reviewer`** на diff — обязательно (non-trivial, catalog-critical).
4. PR → `main`. Merge — **только по явному go-ahead пользователя** (main = prod).

## Follow-up (вне scope, отметить в PR)

`orders_importer.rb:51` архивирует `BuyerOrder` по `seen_ids` **без** проверки на fetch-ошибки
(тот же класс бага, что чинил PR #6, но для orders). Меньший blast-radius (заявки, не каталог),
но стоит завести отдельной задачей.
