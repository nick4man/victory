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

    def initialize(payload)
      @payload = payload.deep_stringify_keys
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
      reasons = REQUIRED.select { |key| @payload[key].blank? }.map { |key| "нет поля #{key}" }
      reasons << 'город вне реестра' if @payload['city'].present? && !known_city?
      reasons << 'битая цена' if price_broken?
      reasons << 'нечитаемый fetched_at' if fetched_at_broken?
      reasons << 'fields не объект' if fields_broken?

      # `model_invalid_reasons` ниже — не бесплатная проверка в памяти:
      # `probe.valid?` реально ходит в базу (см. комментарий там). Если
      # наблюдение уже отвергнуто более дешёвой структурной причиной,
      # гонять пробник незачем — раньше платили эти запросы и за payload,
      # отвергнутый по «город вне реестра».
      return reasons if reasons.any?

      reasons.concat(model_invalid_reasons)
      reasons
    end

    def known_city?
      ResidentialComplex::CITY_NAMES.include?(@payload['city'])
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

    # Единственное array-типизированное поле в `FactApplier::FILLABLE` —
    # `address_patterns` (`character varying[]` в Postgres). Аудит:
    # остальные 12 полей белого списка — `string`/`integer`/enum, для них
    # тип-каст Ruby не подменяет данные молча (строка остаётся строкой,
    # `Integer()`-подобной магии на них нет — числовые поля идут через
    # `type_for_attribute(...).serialize` ниже, а не через угадывание типа).
    ARRAY_FIELDS = %w[address_patterns].freeze

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
    # Три проверки, от дешёвой к дорогой:
    #   1. Массивные поля (`ARRAY_FIELDS`) — сырое значение обязано быть
    #      `Array` САМО ПО СЕБЕ, до какого-либо каста. Постгресовый
    #      array-тип не отвергает не-массив на присвоении — он молча
    #      пытается прочитать строку КАК ЛИТЕРАЛ Postgres («ул. Мира, 5»
    #      режется по запятым побайтово и ломает многобайтовый UTF-8;
    #      `12345` остаётся строкой «12345», не массивом ЦИФР), и
    #      настоящая ошибка (`PG::CharacterNotInRepertoire` / «malformed
    #      array literal») вылезает только на `INSERT`, когда каст уже
    #      исказил данные и транзакция частично выполнена. `.valid?`
    #      здесь бессилен — после каста значение ВСЕГДА `Array`, просто
    #      иногда мусорный.
    #   2. `assign_attributes` — присвоение enum-полю (`housing_class`/
    #      `build_status`) значения вне словаря бросает `ArgumentError`
    #      прямо на сеттере, раньше валидации.
    #   3. `type_overflow_reasons` — число, которое `numericality` считает
    #      нормальным (целое, `> 0`), но которое не влезает в колонку
    #      (`buildings_count: 99999999999` при `int4`): не бросает
    #      исключение ни на присвоении, ни на `.valid?` — только при
    #      попытке ЗАПИСАТЬ значение (`ActiveModel::RangeError`).
    #      `type_for_attribute(...).serialize` вызывает эту же проверку
    #      без обращения к БД (подтверждено экспериментально).
    def model_invalid_reasons
      return [] if fields.empty?

      array_reasons = array_field_reasons
      return array_reasons if array_reasons.any?

      probe = ResidentialComplex.new(name: effective_name, city: @payload['city'])

      begin
        probe.assign_attributes(fields.symbolize_keys)
      rescue ArgumentError => e
        return [e.message]
      end

      overflow_reasons = type_overflow_reasons(probe)
      return overflow_reasons if overflow_reasons.any?

      probe.valid?
      probe.errors.messages.each_with_object([]) do |(attr, messages), acc|
        next unless fields.key?(attr.to_s)

        messages.each { |message| acc << "#{attr} #{message}" }
      end
    end

    def array_field_reasons
      ARRAY_FIELDS.each_with_object([]) do |field, acc|
        next unless fields.key?(field)
        next if fields[field].is_a?(Array)

        acc << "#{field} должен быть массивом"
      end
    end

    def type_overflow_reasons(probe)
      fields.keys.each_with_object([]) do |field, acc|
        ResidentialComplex.type_for_attribute(field).serialize(probe.public_send(field))
      rescue ActiveModel::RangeError, TypeError => e
        acc << "#{field} #{e.message}"
      end
    end

    # @return [String] значение `kind` для точки цены: явный `null` и
    # отсутствие ключа — одно и то же («источник не уточнил вид цены»),
    # а не два разных случая. `price['kind'] || 'from'` и
    # `price.fetch('kind', 'from')` РАСХОДЯТСЯ ровно на явный `null`:
    # `fetch` смотрит только на наличие ключа и возвращает `nil`, если
    # ключ есть, а `kind` не может быть `nil` — колонка `NOT NULL`. Метод
    # общий для проверки (`price_broken?`) и записи (`record_price`), как
    # и `price_per_sqm_value` — иначе одно место сочтёт значение валидным,
    # а другое упадёт `NotNullViolation` на ровно том же payload.
    def price_kind(price)
      (price['kind'] || 'from').to_s
    end

    # @return [Boolean] цена присутствует, но её нельзя записать: сам блок
    # `price` — не хеш, нет `price_per_sqm`, оно не целое положительное
    # число, либо `kind` — не одно из значений enum. Отсутствие блока
    # `price` целиком — НЕ битая цена, это источник, у которого её просто
    # нет.
    #
    # Проверяем ТО ЖЕ значение, что `record_price` в итоге запишет
    # (`price_per_sqm_value`), а не грубо усечённое через truncating
    # `Integer()`: `Integer(65000.7)` тихо возвращает `65000` без ошибки,
    # и наблюдение с дробной ценой проходило бы эту проверку, а затем
    # падало необработанным `RecordInvalid` на `ZhkPricePoint.create!` —
    # модельная `numericality: { only_integer: true }` смотрит на СЫРОЕ
    # значение до типизации и дробь бы отвергла.
    def price_broken?
      price = @payload['price']
      return false if price.blank?
      return true unless price.is_a?(Hash)

      return true if price_per_sqm_value.nil?

      !ZhkPricePoint.kinds.key?(price_kind(price))
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
        fact.update!(value: value.to_s, url: @payload['url'], observed_at: observed_at)
      end
    end

    def record_price(complex)
      price = @payload['price']
      return if price.blank? || price['price_per_sqm'].blank?

      ZhkPricePoint.create!(residential_complex: complex, source: @payload['source'],
                            observed_at: observed_at, price_per_sqm: price_per_sqm_value,
                            kind: price_kind(price), rooms: rooms_value(price),
                            url: @payload['url'])
    end
  end
end
