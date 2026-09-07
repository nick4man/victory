# frozen_string_literal: true

module Zhk
  # Применение одного наблюдения от службы сбора. Здесь и только здесь
  # решается, что из присланного попадёт в справочник: служба сбора таких
  # решений не принимает и в базу не пишет.
  #
  # Порядок вызовов внутри `call` — не произвольный:
  #
  #   1. `record_facts` пишет провенанс ПЕРЕД тем, как спросить
  #      `Discrepancies.fields_for`: расхождение может родиться прямо из
  #      фактов ЭТОГО наблюдения (второй источник против первого,
  #      записанного раньше) — если бы мы спросили раньше, только что
  #      возникший спор остался бы невидим ровно на один прогон.
  #   2. `Discrepancies.fields_for` спрашивается ДО `FactApplier.apply`, а
  #      не после: спорное поле нельзя пускать в применятор вовсе — иначе
  #      он затрёт колонку раньше, чем кто-то (редактор) успеет заметить
  #      конфликт. Спорные поля исключаются из атрибутов заранее, а не
  #      проверяются постфактум.
  #
  # Для СОВСЕМ нового ЖК (`build_draft`) порядок обратный: `FactApplier.
  # apply` вызывается ДО `save!`, пока запись ещё `new_record?` — не из-за
  # расхождений (их для только что построенной записи взяться неоткуда:
  # фактов ни от кого ещё нет), а из-за DB-дефолта `address_patterns =
  # '{}'::varchar[]`: сохрани черновик раньше времени — и `FactApplier`
  # увидел бы уже «существующую» запись с НЕ-nil полем и отказался бы его
  # заполнять на первом же реальном наблюдении.
  class Ingest
    # `reasons` — человекочитаемые причины `:invalid` (вебхуку Task 6 нужно
    # сказать сборщику, что именно не так). `filled` и `discrepancies` —
    # ВСЕГДА массивы на любом пути, а не `nil`: вызывающая сторона по
    # контракту зовёт `result.filled.size` и не обязана каждый раз
    # проверять на `nil` только потому, что путь — не happy path.
    Result = Struct.new(:status, :complex_id, :filled, :discrepancies, :error, :reasons, keyword_init: true)

    # Гонка между `existing_observation` и вставкой наблюдения: пойманное
    # нарушение уникального индекса переводится в это исключение и ловится
    # СНАРУЖИ транзакции — узко, вокруг одной лишь записи наблюдения, а не
    # вокруг всего метода. Если ловить `RecordNotUnique` вокруг всего
    # `call`, нарушение СОВСЕМ ДРУГОГО уникального индекса — например
    # `idx_zhk_facts_identity`, когда две одновременные доставки одного
    # источника про один ЖК и поле гоняются по `find_or_initialize_by` +
    # `update!` без блокировки, — тоже тихо превратилось бы в `:duplicate`
    # при пустой базе: наблюдение потеряно молча, вебхук отвечает успехом,
    # служба сбора не ретраит то, что на самом деле не применилось.
    class DuplicateRace < StandardError; end

    # Симметрично `DuplicateRace`: `rescue ActiveRecord::RecordInvalid`
    # раньше стоял вокруг всей транзакции — под ним было ПЯТЬ пишущих
    # вызовов (`complex.save!` дважды, `record_observation`, `record_facts`,
    # `record_price`), а целится он ровно в один. Сегодня недостижимо
    # (`ZhkObservation`/`ZhkFact`/`ZhkPricePoint` не могут получить
    # невалидные данные — все их поля либо считаны из уже провалидированного
    # `payload`, либо вычислены нами), но форма та же, что была у широкого
    # `rescue ArgumentError`: если однажды в `record_facts` или
    # `record_price` появится своя валидация и она провалится, это должно
    # упасть громко, а не притвориться, что наблюдение было `:invalid`.
    class InvalidComplex < StandardError
      attr_reader :record

      def initialize(record)
        @record = record
        super(record.errors.full_messages.join(', '))
      end
    end

    def self.call(payload)
      new(payload).call
    end

    # Колонки, значение которых вычисляем МЫ, а не источник: их форма от
    # наблюдения не зависит, и требовать «источник не может испортить эту
    # колонку» для них нечего.
    COMPUTED_COLUMNS = %w[id created_at updated_at residential_complex_id digest field].freeze

    # @return [Hash{Class => Array<String>}] всё, что `call` пишет СО СЛОВ
    # источника, по таблицам. Не перечисление в коде, а вывод: для
    # журналов — из схемы (`column_names` минус вычисляемые нами), для
    # карточки — из белого списка `FactApplier::FILLABLE` плюс `name`/
    # `city`, которыми заводится черновик.
    #
    # Смысл метода — не удобство, а граница аудита. Три круга правок
    # подряд ответ на вопрос «прошёл ли я все места того же класса» жил в
    # отчёте, то есть был снимком на момент коммита: он пропустил
    # соседнюю таблицу (`zhk_price_points`) и соседний тип колонки в той
    # же. Здесь тот же вопрос задан кодом —
    # `spec/services/zhk/ingest_writes_spec.rb` перебирает ровно этот
    # список, и новая колонка журнала попадает в перебор сама.
    def self.sourced_columns
      {
        ResidentialComplex => FactApplier::FILLABLE.map(&:to_s) + %w[name city],
        ZhkObservation => ZhkObservation.column_names - COMPUTED_COLUMNS,
        ZhkFact => ZhkFact.column_names - COMPUTED_COLUMNS,
        ZhkPricePoint => ZhkPricePoint.column_names - COMPUTED_COLUMNS
      }
    end

    # @return [Symbol] форма колонки — по СХЕМЕ, а не по списку в коде
    # (список ровно так и устаревал: `ARRAY_FIELDS` был захардкожен, хотя
    # выводится отсюда).
    #
    # 🚨 Порядок веток значим: у `character varying[]` `.type` отвечает
    # `:string` — делегирует в subtype, — поэтому массив распознаётся по
    # КЛАССУ типа и до любого обращения к `.type`. Диспетчер на `.type`
    # отнёс бы `address_patterns` к строковым и проверил не тот инвариант.
    #
    # `else` намеренно поднимает исключение, а не возвращает `nil`:
    # колонка новой формы (boolean, decimal, date) обязана уронить и
    # проверку, и спек-сторож. Молчаливый пропуск воспроизвёл бы ровно
    # тот класс дефекта, ради которого всё это написано.
    def self.column_shape(model, attribute)
      type = model.type_for_attribute(attribute.to_s)
      return :array if type.is_a?(ActiveRecord::ConnectionAdapters::PostgreSQL::OID::Array)
      return :enum if model.defined_enums.key?(attribute.to_s)

      case type.type
      when :integer then :integer
      when :string, :text then :string
      when :datetime then :datetime
      when :json, :jsonb then :json
      else
        raise ArgumentError, "неизвестная форма колонки #{model}##{attribute}: #{type.type}"
      end
    end

    def initialize(payload)
      # Наблюдение обязано быть объектом. `[]`, `"строка"`, `nil` — не
      # «пустое наблюдение», а мусор на входе; раньше это был
      # ЕДИНСТВЕННЫЙ вход, дававший исключение (`NoMethodError` на
      # `deep_stringify_keys`/`[]`) вместо `:invalid`.
      @payload_broken = !payload.is_a?(Hash)
      @payload = @payload_broken ? {} : payload.deep_stringify_keys
    end

    def call
      reasons = structural_invalid_reasons
      if reasons.any?
        return Result.new(status: :invalid, error: reasons.join(', '), reasons: reasons,
                           filled: [], discrepancies: [])
      end

      # Идемпотентность проверяем заранее одним запросом, а не полагаемся
      # на исключение из уникального индекса `idx_zhk_observations_identity`:
      # повторная доставка того же наблюдения — штатный, ожидаемый случай
      # (служба сбора ретраит по таймауту, крон гоняет обход снова), а не
      # аварийная ситуация, и не должна платить цену транзакции с
      # последующим откатом. Уникальный индекс при этом не убираем — он
      # остаётся страховкой на гонку между двумя одновременными доставками
      # одного и того же наблюдения (см. `DuplicateRace` выше).
      existing = existing_observation
      return duplicate_result(existing) if existing

      complex = nil
      was_new = false
      filled = []
      contested = []

      ActiveRecord::Base.transaction do
        complex = matched
        was_new = complex.nil?
        complex ||= build_draft

        # На совсем новой карточке применяем и сохраняем ДО записи
        # наблюдения: `residential_complex_id` наблюдения — `null: true`,
        # но раз id уже известен, писать вместо него `nil` незачем.
        if was_new
          filled = FactApplier.apply(complex, fields.symbolize_keys)
          save_complex!(complex)
        end

        begin
          record_observation(complex)
        rescue ActiveRecord::RecordNotUnique
          raise DuplicateRace
        end

        record_facts(complex)
        contested = Discrepancies.fields_for(complex)

        unless was_new
          filled = FactApplier.apply(complex, fields.except(*contested).symbolize_keys)
          save_complex!(complex)
        end

        record_price(complex)
      end

      Result.new(status: was_new ? :created : :updated, complex_id: complex.id,
                 filled: filled, discrepancies: contested, reasons: [])
    rescue DuplicateRace
      # Транзакция уже откатилась целиком (наблюдение, факты, цена, правка
      # карточки) — конкурирующая доставка успела закоммититься первой,
      # перечитываем её, чтобы отдать тот же `complex_id`, что получил бы
      # обычный дубль.
      duplicate_result(existing_observation)
    rescue InvalidComplex => e
      # Страховка на то, что `model_invalid_reasons` не покрывает: она
      # смотрит только на значения ИЗ ЭТОГО наблюдения по отдельности, а
      # не на их сочетание с уже сохранёнными данными карточки (например
      # `built_from` реальной карточки против `built_to` из наблюдения).
      # Транзакция уже откатилась (исключение поднято внутри
      # `ActiveRecord::Base.transaction`), база чистая.
      Result.new(status: :invalid, error: e.message, reasons: e.record.errors.full_messages,
                 filled: [], discrepancies: [])
    end

    private

    # Служба сбора может прислать что угодно; в справочник (и в провенанс)
    # попадает только то, что разрешено белым списком `FactApplier::FILLABLE`.
    #
    # `@payload['fields'] || {}`, а НЕ `@payload.fetch('fields', {})`:
    # `fetch` подставляет дефолт только когда ключа нет вовсе, а
    # `"fields": null` — самая естественная запись «источник ничего не
    # нашёл», и ключ при этом присутствует со значением `nil`. `fetch`
    # в этом случае вернул бы `nil`, а не `{}`, и `.slice` на `nil` падает
    # `NoMethodError`. `fields_broken?` ниже проверяет РОВНО то же
    # значение тем же способом — иначе тут ровно тот дефект, что уже
    # чинили для `kind` (проверяем одно, читаем другое).
    def fields
      @fields ||= (@payload['fields'] || {}).slice(*FactApplier::FILLABLE.map(&:to_s))
    end

    # @return [Hash] то и только то, что `FactApplier` МОЖЕТ записать.
    # Предикат общий с применятором (`FactApplier.empty_value?`), а не
    # свой такой же — иначе это ровно та пара «проверяем одно, применяем
    # другое», которую уже чинили для `kind` и для `fields`.
    #
    # Провенанс (`record_facts`) при этом пишется на ВСЁ присланное,
    # включая пропущенные здесь значения: пустая строка — утверждение
    # источника «поле пусто», и в журнале ему место, даже когда в колонку
    # оно не поедет.
    def applicable_fields
      @applicable_fields ||= fields.reject { |_, value| FactApplier.empty_value?(value) }
    end

    # Имя, под которым карточка заводится и по которому ищется в справочнике.
    # `fields['name']` — тоже в белом списке `FILLABLE`, а значит на новой
    # записи `FactApplier` применит его как «любое присланное непустое
    # значение». Строить черновик и матчить по `payload['name']`, а
    # применять — по другому `fields['name']`, значило бы, что карточка
    # уедет под вторым именем и слагом от него, а следующее наблюдение
    # того же источника, ищущее по `payload['name']`, её не найдёт — заведёт
    # дубль. Поэтому и `matched`, и `build_draft` используют РОВНО то же
    # имя, что получит `FactApplier`: применение к уже согласованному
    # значению — это no-op, а не расхождение.
    def effective_name
      @effective_name ||= fields['name'].presence || @payload['name']
    end

    REQUIRED = %w[source external_id name city].freeze

    # @return [Array<String>] причины отвергнуть наблюдение целиком, ДО
    # какой-либо записи в базу — включая ДО `record_facts`. Модельные
    # правила (диапазон года, длина имени, неизвестный район) сюда
    # включены сознательно, а не оставлены только `rescue
    # ActiveRecord::RecordInvalid` на `save!`: тот срабатывает лишь когда
    # значение реально доходит до `save!`, а `FactApplier` на СОХРАНЁННОЙ
    # карточке применяет поле только если оно сейчас `nil`. У зрелой
    # карточки почти всё уже заполнено — значит `save!` с мусорным
    # значением просто не случится, мусор тихо осядет в `ZhkFact` как
    # «расхождение», а выйти из этой очереди нечем: экрана разрешения нет,
    # только ручное удаление строк в консоли. `model_invalid_reasons` не
    # зависит от состояния карточки в принципе — она проверяет значения
    # ИЗ ЭТОГО наблюдения сами по себе, на чистом пробнике.
    def structural_invalid_reasons
      return ['payload не объект'] if @payload_broken

      # Три эшелона, и порядок между ними обязателен, а не эстетичен:
      #
      #   1. форма самого наблюдения — есть ли ключи и того ли они типа.
      #      Второй эшелон читает `fields`/`price` как хеши, а
      #      `effective_name` — как строку, и раньше первого работать не
      #      может физически;
      #   2. форма значений по колонкам, куда они уедут (строка в
      #      строковую, массив строк в массивную);
      #   3. доменные правила моделей на пробниках.
      #
      # Третий эшелон вдобавок не бесплатный: `probe.valid?` реально
      # ходит в базу (см. комментарий у `model_invalid_reasons`). Ранние
      # `return` — не только про «первая причина полезнее списка», но и
      # про то, чтобы не платить эти запросы за payload, отвергнутый по
      # «город вне реестра».
      reasons = payload_shape_reasons
      return reasons if reasons.any?

      value_reasons = field_shape_reasons + price_invalid_reasons
      return value_reasons if value_reasons.any?

      model_invalid_reasons
    end

    # Ключи верхнего уровня, каждый из которых уезжает в СТРОКОВУЮ
    # колонку: `source`/`external_id`/`url` — в `zhk_observations` и (без
    # `external_id`) в `zhk_facts`/`zhk_price_points`, `name`/`city` — в
    # `residential_complexes`. Строковый тип Rails кастует `to_s` что
    # угодно, поэтому Hash уехал бы в колонку ruby-инспектом, а `name` —
    # ещё и в ПУБЛИЧНЫЙ слаг от этого инспекта. `nil` — законное «источник
    # не дал ссылку» (для обязательных ключей его ловит `REQUIRED`).
    STRING_KEYS = %w[source external_id url name city].freeze

    # @return [Array<String>] первый эшелон: форма наблюдения как объекта.
    def payload_shape_reasons
      reasons = REQUIRED.select { |key| @payload[key].blank? }.map { |key| "нет поля #{key}" }
      reasons.concat(scalar_string_reasons)
      # `is_a?(String)`, а не `present?`: у нестроки причина уже названа
      # выше, второе сообщение про реестр городов было бы шумом.
      reasons << 'город вне реестра' if @payload['city'].is_a?(String) && !known_city?
      reasons << 'fields не объект' if fields_broken?
      reasons << 'price не объект' if price_shape_broken?
      reasons << 'нечитаемый fetched_at' if fetched_at_broken?
      reasons
    end

    def scalar_string_reasons
      reasons = STRING_KEYS.filter_map do |key|
        value = @payload[key]
        next if value.nil? || value.is_a?(String)

        "#{key} должен быть строкой"
      end
      # `fetched_at` — не строковая колонка, а `datetime`, но по контракту
      # приходит строкой ISO-8601 и разбирается `Time.zone.parse`: та
      # берёт `to_s` от чего угодно, и `{"a"=>"b"}` тихо стал бы
      # «нечитаемой датой» с фолбэком на `Time.current` — момент обхода
      # притворился бы временем применения.
      raw = @payload['fetched_at']
      reasons << 'fetched_at должен быть строкой' unless raw.nil? || raw.is_a?(String)
      reasons
    end

    def known_city?
      ResidentialComplex::CITY_NAMES.include?(@payload['city'])
    end

    # @return [Array<String>] второй эшелон для `fields`: форма значения
    # против формы колонки, куда оно уедет.
    #
    # Целочисленные колонки проверяются здесь ЛИШЬ на исчезновение при
    # касте (см. `integer_shape_reason`) — сам мусор ловит `numericality`
    # на модели, переполнение `int4` — `type_overflow_reasons`.
    def field_shape_reasons
      applicable_fields.filter_map do |field, value|
        shape = self.class.column_shape(ResidentialComplex, field)
        case shape
        when :array then array_shape_reason(field, value)
        when :string, :enum then ("#{field} должен быть строкой" unless value.is_a?(String))
        when :integer then integer_shape_reason(field, value)
        else
          raise ArgumentError, "форма колонки #{shape} не покрыта проверкой (#{field})"
        end
      end
    end

    # Массивная колонка (`address_patterns`, `character varying[]`) не
    # отвергает не-массив на присвоении — Postgres-тип трактует строку
    # как готовый ЛИТЕРАЛ массива и парсит её по запятым ПОБАЙТОВО
    # («ул. Мира, 5» ломает многобайтовый UTF-8), а настоящая ошибка
    # (`PG::CharacterNotInRepertoire` / «malformed array literal»)
    # вылезает только на `INSERT`. Элементы проверяем по той же причине:
    # `[1, 2]` доедет до колонки как `["1", "2"]`, `[{"a"=>"b"}]` — как
    # строка с ruby-инспектом, и обе эти строки потом кормят `Matcher`.
    def array_shape_reason(field, value)
      return "#{field} должен быть массивом" unless value.is_a?(Array)
      return if value.all?(String)

      "#{field} должен быть массивом строк"
    end

    # Третий, самый тихий случай у целочисленной колонки — значение,
    # которое каст ПРЕВРАЩАЕТ В `nil` (Hash, Array). Ни `numericality`,
    # ни `type_overflow_reasons` его не видят: валидатор с `allow_nil`
    # читает значение ПОСЛЕ каста, видит `nil` и пропускает проверку
    # целиком, а применятор присваивает тот же `nil` — источник заявил
    # значение, мы ничего не записали и отчитались `:created`. Найдено
    # сторожем (`ingest_writes_spec`) сразу после его появления, на пяти
    # колонках разом.
    #
    # Мусор, который каст НЕ съедает («две» → `0`, «-5» → `-5`), сюда не
    # попадает и остаётся заботой `numericality` — второе правило про то
    # же самое однажды разъехалось бы с первым.
    def integer_shape_reason(field, value)
      return if ResidentialComplex.type_for_attribute(field).cast(value)

      "#{field} должно быть числом"
    end

    # @return [Boolean] `payload['fields']` — не `nil` и не хеш (массив,
    # строка, число). `fields` трактует ключ так: отсутствует ИЛИ `nil` —
    # «источник ничего не нашёл», иначе — обязан быть хешем. Проверяем
    # ЭТО ЖЕ условие, а не `.present?`: `.present?` у `[]` и `""` — `false`,
    # то есть эти два случая эта проверка раньше пропускала как «не
    # сломано», а `fields` на них падал (`Array#slice`/`String#slice` с
    # 13 строковыми аргументами — `ArgumentError: wrong number of
    # arguments`, не `Hash#slice`). Порядок замеров ревью:
    #
    #   `["developer","Единство"]` → раньше и сейчас `:invalid` (не хеш)
    #   `[]`, `""`                 → раньше падали наружу, сейчас `:invalid`
    #   `null`                     → `fields` трактует как «нет полей», не битое
    def fields_broken?
      raw = @payload['fields']
      !raw.nil? && !raw.is_a?(Hash)
    end

    # @return [Boolean] `fetched_at` не парсится. Единственное известное
    # узкое место для `ArgumentError` здесь — `Time.zone.parse` реально
    # бросает его на невозможных датах («2026-13-45» → `argument out of
    # range»), а не только возвращает `nil`, как на бессмысленном мусоре
    # («not-a-date» → `nil`, штатно уходит в фолбэк `Time.current`).
    def fetched_at_broken?
      Time.zone.parse(@payload['fetched_at'].to_s)
      false
    rescue ArgumentError
      true
    end

    # @return [Array<String>] нарушения доменных правил модели значениями
    # ИЗ ЭТОГО наблюдения — независимо от того, что уже сохранено на
    # карточке (см. комментарий у `structural_invalid_reasons`). Пробник —
    # чистый `ResidentialComplex.new`, ему нечего терять кроме валидности
    # самих значений: ошибка на `name`/`city` в счёт не идёт, если их не
    # прислало ИМЕННО это наблюдение (`fields`), а не заготовка контекста.
    #
    # ЭТО НЕ бесплатная проверка «в памяти, без похода в базу» — так было
    # написано в отчёте прошлого круга, и это было неверно. `probe.valid?`
    # реально шлёт SQL: `friendly_id` с `:history` вешает `before_validation
    # :set_slug`, а генератор кандидата слага проверяет уникальность двумя
    # запросами — по `residential_complexes` и по `friendly_id_slugs`.
    # Цена терпима (на наблюдение, не на HTTP-запрос сайта), но не нулевая
    # — поэтому `structural_invalid_reasons` не гоняет этот метод, если
    # наблюдение уже отвергнуто более дешёвой причиной.
    #
    # Пробнику отдаём РОВНО то, что применит `FactApplier`
    # (`applicable_fields`), а не всё присланное: `{"name": null}` и
    # `{"name": ""}` применятор пропускает всегда, а пробник валидировал
    # их как настоящее имя карточки и ронял наблюдение целиком —
    # `:invalid` с «name Не может быть пустым», вместе с ценой и всеми
    # остальными полями. Тот же круг признал `"fields": null`
    # естественной записью «источник ничего не нашёл»; `{"name": null}`
    # — то же утверждение уровнем ниже.
    #
    # Две проверки, от дешёвой к дорогой (форма значений проверена ещё
    # раньше — `field_shape_reasons`):
    #   1. `assign_attributes` — присвоение enum-полю (`housing_class`/
    #      `build_status`) значения вне словаря бросает `ArgumentError`
    #      прямо на сеттере, раньше валидации.
    #   2. `type_overflow_reasons` — число, которое `numericality` считает
    #      нормальным (целое, `> 0`), но которое не влезает в колонку
    #      (`buildings_count: 99999999999` при `int4`): не бросает
    #      исключение ни на присвоении, ни на `.valid?` — только при
    #      попытке ЗАПИСАТЬ значение (`ActiveModel::RangeError`).
    #      `type_for_attribute(...).serialize` вызывает эту же проверку
    #      без обращения к БД (подтверждено экспериментально).
    def model_invalid_reasons
      return [] if applicable_fields.empty?

      probe = ResidentialComplex.new(name: effective_name, city: @payload['city'])

      begin
        probe.assign_attributes(applicable_fields.symbolize_keys)
      rescue ArgumentError => e
        return [e.message]
      end

      overflow_reasons = type_overflow_reasons(ResidentialComplex, probe, applicable_fields.keys)
      return overflow_reasons if overflow_reasons.any?

      probe.valid?
      probe.errors.messages.each_with_object([]) do |(attr, messages), acc|
        next unless applicable_fields.key?(attr.to_s)

        messages.each { |message| acc << "#{attr} #{message}" }
      end
    end

    # @return [Array<String>] значения, которые проходят и каст, и
    # `valid?`, но физически не влезают в колонку. Общий метод на все
    # пробники: переполнение `int4` — свойство КОЛОНКИ, а не конкретной
    # модели, и `zhk_price_points.price_per_sqm`/`rooms` — ровно такой же
    # `int4`, как `residential_complexes.buildings_count`.
    #
    # Перебираем только целочисленные колонки: у строковых `serialize`
    # это `to_s`, лишний вызов на каждое поле каждого наблюдения, а форму
    # их значения проверяет `field_shape_reasons`.
    #
    # `rescue` ловит ТОЛЬКО `ActiveModel::RangeError`. `TypeError` отсюда
    # убран: он широк — программная ошибка внутри `public_send`/
    # `serialize` стала бы «наблюдение битое», — а несоответствие типа
    # ловится раньше, формой значения.
    def type_overflow_reasons(model, probe, attributes)
      integer_attributes(model, attributes).each_with_object([]) do |attribute, acc|
        model.type_for_attribute(attribute).serialize(probe.public_send(attribute))
      rescue ActiveModel::RangeError => e
        acc << "#{attribute} #{e.message}"
      end
    end

    def integer_attributes(model, attributes)
      attributes.map(&:to_s).select { |attribute| self.class.column_shape(model, attribute) == :integer }
    end

    # @return [String] значение `kind` для точки цены: явный `null` и
    # отсутствие ключа — одно и то же («источник не уточнил вид цены»),
    # а не два разных случая. `price['kind'] || 'from'` и
    # `price.fetch('kind', 'from')` РАСХОДЯТСЯ ровно на явный `null`:
    # `fetch` смотрит только на наличие ключа и возвращает `nil`, если
    # ключ есть, а `kind` не может быть `nil` — колонка `NOT NULL`. Метод
    # общий для проверки (`price_invalid_reasons`) и записи
    # (`record_price`), как
    # и `price_per_sqm_value` — иначе одно место сочтёт значение валидным,
    # а другое упадёт `NotNullViolation` на ровно том же payload.
    def price_kind(price)
      (price['kind'] || 'from').to_s
    end

    # @return [Boolean] блок `price` есть, но он не объект. Симметрично
    # `fields_broken?`: отсутствие и явный `null` — «у источника цены
    # нет», всё остальное обязано быть хешем.
    def price_shape_broken?
      raw = @payload['price']
      !raw.nil? && !raw.is_a?(Hash)
    end

    # @return [Array<String>] причины, по которым точку цены нельзя
    # записать. Отсутствие блока `price` — НЕ причина: это источник, у
    # которого цены просто нет.
    #
    # Пробник `ZhkPricePoint` — тот же приём, что `model_invalid_reasons`
    # для карточки, и заведён по той же причине. `price_per_sqm` и
    # `rooms` — такой же `int4`, как `buildings_count`, но проверялись
    # только через `parse_whole_number`: `99999999999` целое и
    # положительное, прежняя проверка считала такую цену нормальной,
    # модельная `numericality` тоже пропускала, и `ActiveModel::RangeError`
    # вылетал наружу из `create!` — вебхук отдал бы 500, а сборщик
    # ретраил бы вечно. Аудит прошлого круга шёл по
    # `FactApplier::FILLABLE`, а этих двух колонок там нет.
    #
    # Проверяем ТЕ ЖЕ значения, что `record_price` в итоге запишет
    # (`price_per_sqm_value`/`rooms_value`), а не сырые: грубо усечённое
    # `Integer(65000.7)` тихо вернуло бы `65000`, а сырое `65000.0`
    # споткнулось бы о `only_integer` там, где запись прошла бы.
    def price_invalid_reasons
      price = @payload['price']
      return [] if price.blank?

      reasons = []
      reasons << 'битая цена' if price_per_sqm_value.nil?
      reasons << 'kind вне словаря' unless ZhkPricePoint.kinds.key?(price_kind(price))
      # Источник заявил число комнат, а прочитать его мы не смогли.
      # Молча выбросить заявленное значение — то же самое, что тихо
      # кастовать «студию» в `0`, только незаметнее.
      reasons << 'rooms не целое неотрицательное число' if rooms_broken?(price)
      return reasons if reasons.any?

      price_probe_reasons(price)
    end

    def rooms_broken?(price)
      !price['rooms'].nil? && rooms_value(price).nil?
    end

    # Ошибки пробника фильтруем по колонкам, которые заполняет источник:
    # `belongs_to :residential_complex` на пробнике не заполнен намеренно
    # (ЖК на этот момент ещё не найден и не заведён), и «должен
    # существовать» — не претензия к наблюдению.
    def price_probe_reasons(price)
      probe = ZhkPricePoint.new(source: @payload['source'], observed_at: observed_at,
                                price_per_sqm: price_per_sqm_value, kind: price_kind(price),
                                rooms: rooms_value(price), url: @payload['url'])
      sourced = self.class.sourced_columns[ZhkPricePoint]

      overflow_reasons = type_overflow_reasons(ZhkPricePoint, probe, sourced)
      return overflow_reasons if overflow_reasons.any?

      probe.valid?
      probe.errors.messages.each_with_object([]) do |(attr, messages), acc|
        next unless sourced.include?(attr.to_s)

        messages.each { |message| acc << "#{attr} #{message}" }
      end
    end

    # @return [Integer, nil] `price_per_sqm` как целое положительное число,
    # если оно РОВНО целое (без дробной части) — иначе `nil`. Строка,
    # число с плавающей точкой и целое обрабатываются одинаково: важно не
    # то, каким типом пришло значение, а то, что оно действительно целое.
    def price_per_sqm_value
      value = parse_whole_number(@payload.dig('price', 'price_per_sqm'))
      value if value&.positive?
    end

    # @return [Integer, nil] число комнат, если оно целое неотрицательное,
    # иначе `nil`. Модель трактует `0` как «студия» — осмысленное значение,
    # а не «данных нет», поэтому мусор («студия» строкой) нельзя тихо
    # кастовать в `0` через `String#to_i`: он вернёт `0` для ЛЮБОГО
    # нечислового префикса, и мусор станет неотличим от настоящей студии.
    def rooms_value(price)
      parse_whole_number(price['rooms'])
    end

    # Общий парсер «целое неотрицательное число или ничего» для двух полей
    # выше: `Integer`/`Float` с нулевой дробной частью, либо строка из
    # одних цифр. Всё остальное (дробь, буквы, `nil`) — `nil`, а не «0» и
    # не молчаливое усечение.
    def parse_whole_number(raw)
      case raw
      when Integer
        raw if raw >= 0
      when Float
        raw.to_i == raw && raw >= 0 ? raw.to_i : nil
      when String
        /\A\d+\z/.match?(raw) ? raw.to_i : nil
      end
    end

    def digest
      # `fetched_at` намеренно исключён: это момент обхода, а не содержимое
      # находки. Один и тот же ЖК, обойдённый повторно с тем же контентом,
      # обязан дать тот же digest, иначе идемпотентность работала бы только
      # в пределах одного HTTP-запроса службы сбора.
      @digest ||= Digest::SHA256.hexdigest(@payload.except('fetched_at').to_json)
    end

    # @return [ZhkObservation, nil] то же наблюдение, если оно уже
    # применено — по нему же берём `residential_complex_id` для ответа на
    # повторную доставку, а не только факт «уже было».
    def existing_observation
      ZhkObservation.find_by(source: @payload['source'], external_id: @payload['external_id'],
                            digest: digest)
    end

    def duplicate_result(observation)
      Result.new(status: :duplicate, complex_id: observation&.residential_complex_id,
                 filled: [], discrepancies: [], reasons: [])
    end

    # Узкая обёртка вокруг ЕДИНСТВЕННОГО места, куда реально целится
    # `rescue InvalidComplex` в `call` — см. комментарий у самого класса
    # `InvalidComplex`.
    def save_complex!(complex)
      complex.save!
    rescue ActiveRecord::RecordInvalid
      raise InvalidComplex, complex
    end

    def matched
      Matcher.call(name: effective_name, city: @payload['city'], address: fields['address'])
    end

    def build_draft
      ResidentialComplex.new(name: effective_name, city: @payload['city'], published: false)
    end

    def observed_at
      @observed_at ||= Time.zone.parse(@payload['fetched_at'].to_s) || Time.current
    end

    def record_observation(complex)
      ZhkObservation.create!(source: @payload['source'], external_id: @payload['external_id'],
                            url: @payload['url'], fetched_at: observed_at,
                            payload: @payload, digest: digest, residential_complex: complex)
    end

    # Провенанс пишется на ВСЁ присланное (в рамках белого списка), а не
    # только на то, что в итоге попало в колонку: иначе расхождение между
    # источниками негде увидеть — колонка хранит одно значение, а спор
    # виден только по журналу фактов.
    def record_facts(complex)
      fields.each do |field, value|
        fact = ZhkFact.find_or_initialize_by(residential_complex: complex, field: field,
                                             source: @payload['source'])
        # `nil` пишем как `NULL`, а НЕ как `value.to_s` → `''`. Разница
        # не косметическая: `Discrepancies` в собственном комментарии
        # постулирует, что `nil` — «источник промолчал» (строку не
        # рассматриваем), а пустая строка — «источник осмотрел поле и
        # заявил пустоту» (полноценное мнение, спорящее с непустым
        # мнением соседа). `to_s` стирал эту разницу и делал из молчания
        # утверждение: `{"developer": null}` против «Единство» уводило
        # поле в `contested` навсегда — `FactApplier` его больше не
        # трогает, а экрана разрешения расхождений не существует.
        # Побочно это оживляет `where.not(value: nil)` в `Discrepancies`,
        # который до сих пор был мёртвым кодом.
        fact.update!(value: value.nil? ? nil : value.to_s, url: @payload['url'],
                     observed_at: observed_at)
      end
    end

    def record_price(complex)
      price = @payload['price']
      # Условие пропуска — ТО ЖЕ значение и тем же способом, что у
      # `price_invalid_reasons` (`price_per_sqm_value`), а не соседняя
      # проверка `price['price_per_sqm'].blank?` по сырому ключу: иначе
      # одно место считает цену отсутствующей, другое — записываемой.
      return if price.blank? || price_per_sqm_value.nil?

      ZhkPricePoint.create!(residential_complex: complex, source: @payload['source'],
                            observed_at: observed_at, price_per_sqm: price_per_sqm_value,
                            kind: price_kind(price), rooms: rooms_value(price),
                            url: @payload['url'])
    end
  end
end
