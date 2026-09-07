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
  # Для СОВСЕМ нового ЖК (`build_draft`) порядок исключение: `record_facts`
  # требует `residential_complex_id` (FK `null: false`), а у ещё не
  # сохранённой записи id нет. Сохранить черновик заранее, чтобы получить
  # id, тоже нельзя без потерь: `address_patterns` в БД имеет дефолт
  # `'{}'::varchar[]`, а не NULL, и после `save!` `FactApplier` увидел бы
  # уже несохранённую запись как «существующую» с НЕ-nil полем — и отказался
  # бы его заполнять, хотя источник прислал первое и единственное мнение.
  # Поэтому на совсем новой карточке `FactApplier.apply` вызывается ДО
  # `save!`, пока запись ещё `new_record?` — это безопасно: у только что
  # построенной записи фактов вообще ни от кого нет, расхождению взяться
  # неоткуда, исключать нечего.
  class Ingest
    Result = Struct.new(:status, :complex_id, :filled, :discrepancies, :error, keyword_init: true)

    def self.call(payload)
      new(payload).call
    end

    def initialize(payload)
      @payload = payload.deep_stringify_keys
    end

    def call
      reasons = invalid_reasons
      return Result.new(status: :invalid, error: reasons.join(', ')) if reasons.any?

      # Идемпотентность проверяем заранее, а не полагаемся на исключение из
      # уникального индекса `idx_zhk_observations_identity`: повторная
      # доставка того же наблюдения — штатный, ожидаемый случай (служба
      # сбора ретраит по таймауту, крон гоняет обход снова), а не аварийная
      # ситуация, и не должна платить цену транзакции с последующим
      # откатом. Уникальный индекс при этом не убираем — он остаётся
      # страховкой на гонку между двумя одновременными доставками одного и
      # того же наблюдения (rescue ниже).
      return Result.new(status: :duplicate) if seen_before?

      complex = nil
      was_new = false
      filled = []
      contested = []

      ActiveRecord::Base.transaction do
        complex = matched
        was_new = complex.nil?
        complex ||= build_draft

        record_observation

        if was_new
          filled = FactApplier.apply(complex, fields.symbolize_keys)
          complex.save!
          record_facts(complex)
          contested = Discrepancies.fields_for(complex)
        else
          record_facts(complex)
          contested = Discrepancies.fields_for(complex)
          filled = FactApplier.apply(complex, fields.except(*contested).symbolize_keys)
          complex.save!
        end

        record_price(complex)
      end

      Result.new(status: was_new ? :created : :updated, complex_id: complex.id,
                 filled: filled, discrepancies: contested)
    rescue ActiveRecord::RecordNotUnique
      # Гонка: между проверкой `seen_before?` и вставкой то же наблюдение
      # успела записать параллельная доставка. Транзакция откатилась целиком
      # (наблюдение, факты, цена, правка карточки) — снаружи это неотличимо
      # от штатного дубля.
      Result.new(status: :duplicate)
    end

    private

    # Служба сбора может прислать что угодно; в справочник (и в провенанс)
    # попадает только то, что разрешено белым списком `FactApplier::FILLABLE`.
    def fields
      @fields ||= @payload.fetch('fields', {}).slice(*FactApplier::FILLABLE.map(&:to_s))
    end

    REQUIRED = %w[source external_id name city].freeze

    # @return [Array<String>] причины отвергнуть наблюдение целиком, не
    # доводя дело до записи в базу и не полагаясь на исключение валидации
    # где-то в глубине (`ZhkObservation`/`ResidentialComplex`).
    def invalid_reasons
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
    def price_broken?
      price = @payload['price']
      return false if price.blank?

      value = Integer(price['price_per_sqm'], exception: false)
      return true if value.nil? || !value.positive?

      kind = (price['kind'] || 'from').to_s
      !ZhkPricePoint.kinds.key?(kind)
    end

    def digest
      # `fetched_at` намеренно исключён: это момент обхода, а не содержимое
      # находки. Один и тот же ЖК, обойдённый повторно с тем же контентом,
      # обязан дать тот же digest, иначе идемпотентность работала бы только
      # в пределах одного HTTP-запроса службы сбора.
      @digest ||= Digest::SHA256.hexdigest(@payload.except('fetched_at').to_json)
    end

    def seen_before?
      ZhkObservation.exists?(source: @payload['source'], external_id: @payload['external_id'],
                             digest: digest)
    end

    def matched
      Matcher.call(name: @payload['name'], city: @payload['city'], address: fields['address'])
    end

    def build_draft
      ResidentialComplex.new(name: @payload['name'], city: @payload['city'], published: false)
    end

    def observed_at
      @observed_at ||= Time.zone.parse(@payload['fetched_at'].to_s) || Time.current
    end

    def record_observation
      ZhkObservation.create!(source: @payload['source'], external_id: @payload['external_id'],
                            url: @payload['url'], fetched_at: observed_at,
                            payload: @payload, digest: digest)
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
                            observed_at: observed_at, price_per_sqm: price['price_per_sqm'],
                            kind: price.fetch('kind', 'from'), rooms: price['rooms'],
                            url: @payload['url'])
    end
  end
end
