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
          complex.save!
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
          complex.save!
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
    rescue ActiveRecord::RecordInvalid => e
      # Модельные валидации (`district_slug` вне реестра города, `built_to`
      # вне диапазона, `built_from` позже `built_to`, слишком длинное имя
      # и т. п.) — штатный повод отказать наблюдению, а не 500: `district_
      # slug` и `name` входят в `FactApplier::FILLABLE`, то есть это
      # обычная поверхность контракта наблюдения, не экзотика. Транзакция
      # уже откатилась (исключение поднято внутри `ActiveRecord::Base.
      # transaction`), база чистая.
      Result.new(status: :invalid, error: e.message, reasons: e.record.errors.full_messages,
                 filled: [], discrepancies: [])
    rescue ArgumentError => e
      # Битый `fetched_at` (не парсится `Time.zone.parse`) или недопустимое
      # значение enum-поля (`housing_class`/`build_status` не из словаря) —
      # тоже штатный `:invalid`, а не необработанное исключение.
      Result.new(status: :invalid, error: e.message, reasons: [e.message], filled: [], discrepancies: [])
    end

    private

    # Служба сбора может прислать что угодно; в справочник (и в провенанс)
    # попадает только то, что разрешено белым списком `FactApplier::FILLABLE`.
    def fields
      @fields ||= @payload.fetch('fields', {}).slice(*FactApplier::FILLABLE.map(&:to_s))
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

    # @return [Array<String>] структурные причины отвергнуть наблюдение до
    # какой-либо записи в базу: отсутствующие поля, город вне реестра,
    # заведомо битая цена. Модельные валидации (диапазон года, длина имени,
    # неизвестный район) сюда намеренно не дублируются — их проверяет сама
    # модель на `save!`, а `rescue ActiveRecord::RecordInvalid` в `call`
    # превращает их в тот же `:invalid`, не расходясь с источником правды
    # о том, что для карточки валидно.
    def structural_invalid_reasons
      reasons = REQUIRED.select { |key| @payload[key].blank? }.map { |key| "нет поля #{key}" }
      reasons << 'город вне реестра' if @payload['city'].present? && !known_city?
      reasons << 'битая цена' if price_broken?
      reasons
    end

    def known_city?
      ResidentialComplex::CITY_NAMES.include?(@payload['city'])
    end

    # @return [Boolean] цена присутствует, но её нельзя записать: нет
    # `price_per_sqm`, оно не целое положительное число, либо `kind` — не
    # одно из значений enum. Отсутствие блока `price` целиком — НЕ битая
    # цена, это источник, у которого её просто нет.
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

      return true if price_per_sqm_value.nil?

      kind = (price['kind'] || 'from').to_s
      !ZhkPricePoint.kinds.key?(kind)
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
                 filled: [], discrepancies: [])
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
                            kind: price.fetch('kind', 'from'), rooms: rooms_value(price),
                            url: @payload['url'])
    end
  end
end
