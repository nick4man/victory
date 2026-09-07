# frozen_string_literal: true

require 'rails_helper'

# Сторож, а не аудит.
#
# Четыре круга правок подряд ответ на вопрос «прошёл ли я все места того же
# класса» жил в отчёте — то есть был снимком на момент коммита. Снимок
# устаревал молча и каждый раз пропускал соседа: `fetch`/`present?` на
# `fields` после починки `kind`; три целочисленных поля после починки
# `rooms`; `price_per_sqm`/`rooms` в СОСЕДНЕЙ таблице после починки
# `buildings_count` в белом списке.
#
# Здесь тот же вопрос задан кодом. Перебираются ВСЕ колонки, которые
# `Zhk::Ingest` пишет со слов источника (`sourced_columns` выводит их из
# схемы журналов и из `FactApplier::FILLABLE`), и на каждую требуется два
# инварианта:
#
#   1. мусор формы этой колонки отвергается как `:invalid` — не кастуется
#      молча в правдоподобное значение и не летит исключением наружу
#      (вебхук отдал бы 500, а сборщик ретраил бы вечно);
#   2. легальное значение действительно доезжает до базы. Без второго
#      инварианта первый удовлетворяется отказом от всего подряд, и
#      ловушка вроде `next unless value.present?` (отбрасывает `false`
#      вместе с пустотой) осталась бы невидимой.
#
# Колонка новой формы (boolean, decimal, date) уронит `column_shape`,
# колонка без инъектора или без легального значения — уронит этот спек.
RSpec.describe Zhk::Ingest do
  let(:payload) { JSON.parse(Rails.root.join('spec/fixtures/zhk/observation_example.json').read) }

  # Легальное значение на колонку. Нет записи — спек падает, а не молча
  # пропускает: новая колонка обязана прийти со своим инвариантом.
  LEGAL_VALUES = {
    'name' => 'Новый ЖК',
    'city' => 'Рязань',
    'district_slug' => 'kanishchevo',
    'developer' => 'Атом',
    'address' => 'Рязань, ул. Мира, 5',
    'address_patterns' => ['ул. Мира, 5'],
    'built_from' => 2020,
    'built_to' => 2024,
    'buildings_count' => 7,
    'floors_min' => 5,
    'floors_max' => 25,
    'wall_material' => 'монолит',
    'housing_class' => 'comfort',
    'build_status' => 'completed',
    'source' => 'domrf',
    'external_id' => 'domrf:77',
    'url' => 'https://example.com/zhk/skobelev',
    'fetched_at' => '2026-09-06T05:00:00Z',
    'observed_at' => '2026-09-06T05:00:00Z',
    'value' => 'Атом',
    'price_per_sqm' => 70_000,
    'kind' => 'median',
    'rooms' => 2
  }.freeze

  def with_field(source, key, value)
    source.merge('fields' => (source['fields'] || {}).merge(key => value))
  end

  def with_price(source, key, value)
    source.merge('price' => (source['price'] || {}).merge(key => value))
  end

  # Куда в наблюдении кладётся значение этой колонки. Одно место payload
  # часто питает несколько таблиц сразу (`source` — все три журнала), и
  # это не дублирование, а суть: инвариант требуется от каждой колонки
  # отдельно.
  def special_injectors
    {
      # `name` уезжает и в матчинг (`payload['name']`), и в применятор
      # (`fields['name']`) — оба входа обязаны держать форму.
      'name' => ->(p, v) { with_field(p.merge('name' => v), 'name', v) },
      'city' => ->(p, v) { p.merge('city' => v) },
      'source' => ->(p, v) { p.merge('source' => v) },
      'external_id' => ->(p, v) { p.merge('external_id' => v) },
      'url' => ->(p, v) { p.merge('url' => v) },
      'fetched_at' => ->(p, v) { p.merge('fetched_at' => v) },
      'observed_at' => ->(p, v) { p.merge('fetched_at' => v) },
      'payload' => ->(_p, v) { v },
      # `zhk_facts.value` — это любое значение `fields`, взятое как
      # представитель.
      'value' => ->(p, v) { with_field(p, 'developer', v) },
      'price_per_sqm' => ->(p, v) { with_price(p, 'price_per_sqm', v) },
      'kind' => ->(p, v) { with_price(p, 'kind', v) },
      'rooms' => ->(p, v) { with_price(p, 'rooms', v) }
    }
  end

  def injector_for(column)
    special = special_injectors
    return special[column] if special.key?(column)
    return ->(p, v) { with_field(p, column, v) } if Zhk::FactApplier::FILLABLE.map(&:to_s).include?(column)

    raise "нет инъектора для колонки #{column} — новая колонка обязана прийти со своим инвариантом"
  end

  # Мусор ФОРМЫ этой колонки: минимум два значения на форму, чтобы
  # инвариант не удовлетворялся случайной проверкой на один конкретный тип.
  def garbage_for(shape)
    case shape
    when :string   then [{ 'ключ' => 'значение' }, 12_345]
    when :integer  then [{ 'ключ' => 'значение' }, 99_999_999_999]
    when :enum     then ['нет-такого-значения', 12_345]
    when :array    then ['ул. Мира, 5', [{ 'ключ' => 'значение' }]]
    # 🚨 У даты ТРИ способа быть мусором, и закрываются они разными
    # проверками: «2026-13-45» бросает ArgumentError, «позавчера» молча
    # возвращает nil, Hash отсекается формой. Без третьего значения
    # сторож давал ложное спокойствие — тихой подмены датой применения
    # он не видел.
    when :datetime then ['2026-13-45', 'позавчера', { 'ключ' => 'значение' }]
    when :json     then ['строка вместо объекта', []]
    else raise "нет мусора для формы #{shape}"
    end
  end

  def legal_for(column, source)
    # Колонка `payload` хранит наблюдение целиком — легальное значение
    # для неё это само наблюдение.
    return source if column == 'payload'

    LEGAL_VALUES.fetch(column) { raise "нет легального значения для колонки #{column}" }
  end

  def written_value(model, column, result)
    record = case model.name
             when 'ResidentialComplex' then ResidentialComplex.unscoped.find(result.complex_id)
             when 'ZhkObservation' then ZhkObservation.last
             # Факт пишется на каждое поле `fields`; берём того же
             # представителя, что и инъектор `value`.
             when 'ZhkFact' then ZhkFact.find_by!(field: 'developer')
             when 'ZhkPricePoint' then ZhkPricePoint.last
             else raise "нет читателя для #{model}"
             end
    record.public_send(column)
  end

  described_class.sourced_columns.each do |model, columns|
    columns.each do |column|
      describe "#{model}##{column} — колонка формы #{described_class.column_shape(model, column)}" do
        let(:shape) { described_class.column_shape(model, column) }

        it 'отвергает мусор этой формы как :invalid, а не кастует и не роняет исключение' do
          garbage_for(shape).each do |garbage|
            broken = injector_for(column).call(payload.deep_dup, garbage)

            result = nil
            expect { result = described_class.call(broken) }.not_to raise_error
            expect(result.status).to eq(:invalid), "#{column} = #{garbage.inspect} → #{result.status}"
            expect(ResidentialComplex.count).to eq(0)
            expect(ZhkObservation.count).to eq(0)
          end
        end

        it 'записывает легальное значение в колонку' do
          legal = legal_for(column, payload)
          result = described_class.call(injector_for(column).call(payload.deep_dup, legal))

          expect(result.status).to eq(:created)
          expected = shape == :datetime ? Time.zone.parse(legal) : legal
          expect(written_value(model, column, result)).to eq(expected)
        end
      end
    end
  end

  describe '.sourced_columns' do
    it 'перечисляет каждую колонку ровно один раз' do
      # `name` приходит и из белого списка, и из заготовки черновика:
      # без `.uniq` сторож гонял бы по этой колонке два одинаковых
      # набора примеров, а счёт колонок в отчёте расходился бы с числом
      # реальных.
      described_class.sourced_columns.each do |model, columns|
        expect(columns).to eq(columns.uniq), "#{model}: #{columns.tally.select { |_, n| n > 1 }}"
      end
    end
  end

  describe '.column_shape' do
    it 'распознаёт массивную колонку по классу типа, а не по .type' do
      # У `character varying[]` `.type` делегирует в subtype и отвечает
      # `:string`. Диспетчер на `.type` отнёс бы `address_patterns` к
      # строковым и проверил не тот инвариант.
      expect(ResidentialComplex.type_for_attribute('address_patterns').type).to eq(:string)
      expect(described_class.column_shape(ResidentialComplex, 'address_patterns')).to eq(:array)
    end

    it 'падает на колонке новой формы, а не пропускает её молча' do
      # Ровно этот `raise` и делает перебор выше сторожем: булева колонка
      # (или decimal, или date) обязана уронить спек, а не тихо не найти
      # для себя ветку.
      expect { described_class.column_shape(ResidentialComplex, 'published') }
        .to raise_error(ArgumentError, /неизвестная форма колонки/)
    end
  end
end
