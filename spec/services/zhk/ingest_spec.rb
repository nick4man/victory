# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Zhk::Ingest do
  let(:payload) { JSON.parse(Rails.root.join('spec/fixtures/zhk/observation_example.json').read) }

  it 'заводит черновик, когда такого ЖК в справочнике нет' do
    result = described_class.call(payload)

    expect(result.status).to eq(:created)
    complex = ResidentialComplex.unscoped.find(result.complex_id)
    expect(complex.name).to eq('Скобелев')
    expect(complex.published).to be false
    expect(complex.developer).to eq('Единство')
  end

  it 'пишет провенанс на каждое присланное поле, а не только на заполненные' do
    create(:residential_complex, name: 'Скобелев', city: 'Рязань', developer: 'Правка редактора')

    described_class.call(payload)

    fact = ZhkFact.find_by(field: 'developer', source: 'erz')
    expect(fact.value).to eq('Единство')
    expect(fact.url).to eq(payload['url'])
  end

  it 'не переприменяет то же наблюдение — идемпотентность по digest' do
    first = described_class.call(payload)
    complex_id = ResidentialComplex.find_by(name: 'Скобелев').id

    second = described_class.call(payload)

    expect(second.status).to eq(:duplicate)
    # Повторная доставка обязана вернуть тот же complex_id, что и первая:
    # иначе ответ на ретрай отличается от ответа на первую доставку, и
    # сборщик не может считать повтор успешным.
    expect(second.complex_id).to eq(first.complex_id)
    expect(second.filled).to eq([])
    expect(second.discrepancies).to eq([])
    expect(ZhkObservation.count).to eq(1)
    # Идемпотентность — это не только «не создался второй наблюдение», но и
    # «ничего вообще не изменилось»: ни фактов, ни точек цены, ни карточки.
    expect(ZhkFact.where(residential_complex_id: complex_id).count).to eq(4)
    expect(ZhkPricePoint.where(residential_complex_id: complex_id).count).to eq(1)
  end

  it 'поднимает расхождение, когда второй источник спорит с первым' do
    described_class.call(payload)

    other = payload.merge('source' => 'developer_site', 'external_id' => 'edinstvo:83',
                          'fields' => { 'developer' => 'Другой застройщик' })
    result = described_class.call(other)

    expect(result.discrepancies).to include('developer')
  end

  it 'не применяет спорное поле к карточке' do
    complex = create(:residential_complex, name: 'Скобелев', city: 'Рязань', developer: nil)
    # Расхождение уже существует ДО этого наблюдения — от двух источников,
    # ни один из которых ещё не был применён к карточке.
    ZhkFact.create!(residential_complex: complex, field: 'developer', value: 'Альфа',
                     source: 'a', observed_at: Time.current)
    ZhkFact.create!(residential_complex: complex, field: 'developer', value: 'Бета',
                     source: 'b', observed_at: Time.current)

    third = payload.merge('source' => 'c', 'external_id' => 'c:1')
    result = described_class.call(third)

    expect(result.discrepancies).to include('developer')
    expect(complex.reload.developer).to be_nil
  end

  it 'записывает точку цены с пометкой, что это за цена' do
    described_class.call(payload)

    point = ZhkPricePoint.last
    expect(point.price_per_sqm).to eq(65_000)
    expect(point.kind_from?).to be true
  end

  it 'отвергает наблюдение без имени' do
    result = described_class.call(payload.except('name'))

    expect(result.status).to eq(:invalid)
    expect(result.filled).to eq([])
    expect(result.discrepancies).to eq([])
  end

  it 'отвергает наблюдение без источника' do
    expect(described_class.call(payload.except('source')).status).to eq(:invalid)
  end

  it 'отвергает наблюдение с городом вне реестра' do
    expect(described_class.call(payload.merge('city' => 'Атлантида')).status).to eq(:invalid)
  end

  it 'отвергает наблюдение с битой ценой' do
    broken = payload.merge('price' => { 'kind' => 'from', 'price_per_sqm' => -5 })

    expect(described_class.call(broken).status).to eq(:invalid)
  end

  it 'отвергает дробную цену за м², а не молча усекает её до целого' do
    # `Integer(65000.7)` тихо вернул бы 65000 без ошибки — источник данных
    # прислал дробь, и это не то же самое, что целая цена 65000.
    broken = payload.merge('price' => { 'kind' => 'from', 'price_per_sqm' => 65_000.7 })

    result = described_class.call(broken)

    expect(result.status).to eq(:invalid)
    expect(ZhkPricePoint.count).to eq(0)
  end

  it 'ничего не оставляет после себя при исключении в середине применения' do
    allow(Zhk::FactApplier).to receive(:apply).and_raise('boom')

    expect { described_class.call(payload) }.to raise_error('boom')

    expect(ZhkObservation.count).to eq(0)
    expect(ZhkFact.count).to eq(0)
    expect(ZhkPricePoint.count).to eq(0)
    expect(ResidentialComplex.count).to eq(0)
  end

  it 'не глотает нарушение уникального индекса, которое не про идемпотентность самого наблюдения' do
    # `rescue ActiveRecord::RecordNotUnique` стоит узко — вокруг вставки
    # самого наблюдения. Нарушение того же класса исключения где-то ещё
    # (здесь — сымитировано в FactApplier) не должно тихо превращаться в
    # `:duplicate` при пустой базе: это потеряло бы наблюдение молча.
    allow(Zhk::FactApplier).to receive(:apply).and_raise(ActiveRecord::RecordNotUnique, 'чужая гонка')

    expect { described_class.call(payload) }.to raise_error(ActiveRecord::RecordNotUnique)
    expect(ZhkObservation.count).to eq(0)
  end

  it 'отвергает неизвестный район вместо необработанного исключения' do
    with_district = payload.merge('fields' => payload['fields'].merge('district_slug' => 'нет-такого-района'))

    result = described_class.call(with_district)

    expect(result.status).to eq(:invalid)
    expect(result.reasons).to be_present
    expect(ResidentialComplex.count).to eq(0)
  end

  it 'отвергает год сдачи вне диапазона вместо необработанного исключения' do
    with_year = payload.merge('fields' => payload['fields'].merge('built_to' => 3000))

    result = described_class.call(with_year)

    expect(result.status).to eq(:invalid)
    expect(ResidentialComplex.count).to eq(0)
  end

  it 'отвергает built_from позже built_to вместо необработанного исключения' do
    ordered_wrong = payload.merge('fields' => payload['fields'].merge('built_from' => 2030, 'built_to' => 2020))

    result = described_class.call(ordered_wrong)

    expect(result.status).to eq(:invalid)
    expect(ResidentialComplex.count).to eq(0)
  end

  it 'отвергает слишком длинное имя вместо необработанного исключения' do
    too_long = payload.merge('name' => 'Ж' * 200)

    result = described_class.call(too_long)

    expect(result.status).to eq(:invalid)
    expect(ResidentialComplex.count).to eq(0)
  end

  it 'отвергает нечитаемый fetched_at вместо необработанного исключения' do
    broken_date = payload.merge('fetched_at' => '2026-13-45')

    result = described_class.call(broken_date)

    expect(result.status).to eq(:invalid)
    expect(ResidentialComplex.count).to eq(0)
    expect(ZhkObservation.count).to eq(0)
  end

  it 'не кастует мусор в rooms к 0 — студия должна быть настоящим нулём, а не по умолчанию' do
    with_rooms = payload.merge('price' => payload['price'].merge('rooms' => 'студия'))

    described_class.call(with_rooms)

    expect(ZhkPricePoint.last.rooms).to be_nil
  end

  it 'заполняет ветку :updated, а не только :created' do
    create(:residential_complex, name: 'Скобелев', city: 'Рязань', developer: nil, address: nil,
                                  built_to: nil, buildings_count: nil)

    result = described_class.call(payload)

    expect(result.status).to eq(:updated)
    expect(result.filled).to include(:developer, :built_to, :buildings_count, :address)
  end

  it 'явный null у kind — то же самое, что отсутствие ключа, а не поломка записи' do
    # `price['kind'] || 'from'` и `price.fetch('kind', 'from')` расходятся
    # ровно на явный `null`: fetch увидит ключ и вернёт nil, а kind — NOT
    # NULL колонка. Коллектор шлёт настоящие null (см. fixture: rooms).
    with_null_kind = payload.merge('price' => payload['price'].merge('kind' => nil))

    result = described_class.call(with_null_kind)

    expect(result.status).to eq(:created)
    expect(ZhkPricePoint.last.kind_from?).to be true
  end

  it 'reasons у :duplicate — всегда массив, а не nil' do
    described_class.call(payload)

    second = described_class.call(payload)

    expect(second.reasons).to eq([])
  end

  it 'не глотает ArgumentError, который не про одно из двух известных мест' do
    # Единственные два законных источника ArgumentError — Time.zone.parse
    # для fetched_at и присвоение enum вне словаря, оба закрыты своими
    # узкими rescue ДО транзакции. Любой другой ArgumentError (здесь —
    # сымитирован в Matcher) обязан долететь наружу как есть, а не
    # превратиться в лживый :invalid, маскируя реальный баг.
    allow(Zhk::Matcher).to receive(:call).and_raise(ArgumentError, 'непредвиденный баг где-то ещё')

    expect { described_class.call(payload) }.to raise_error(ArgumentError, 'непредвиденный баг где-то ещё')
  end

  it 'отвергает недопустимое значение enum-поля вместо необработанного исключения' do
    bad_enum = payload.merge('fields' => payload['fields'].merge('housing_class' => 'ультра-элит'))

    result = described_class.call(bad_enum)

    expect(result.status).to eq(:invalid)
    expect(ResidentialComplex.count).to eq(0)
  end

  it 'отвергает нехеш price вместо необработанного исключения' do
    broken = payload.merge('price' => 'дёшево')

    result = described_class.call(broken)

    expect(result.status).to eq(:invalid)
    expect(ZhkPricePoint.count).to eq(0)
  end

  it 'отвергает нехеш fields вместо необработанного исключения' do
    broken = payload.merge('fields' => %w[developer Единство])

    result = described_class.call(broken)

    expect(result.status).to eq(:invalid)
    expect(ResidentialComplex.count).to eq(0)
  end

  it 'отвергает мусорное значение независимо от того, что уже заполнено на карточке' do
    # Ровно сценарий из ревью: built_to уже занят на зрелой карточке,
    # FactApplier его не тронет — без пред-валидации мусор тихо ушёл бы в
    # ZhkFact как расхождение, без выхода из очереди.
    create(:residential_complex, name: 'Скобелев', city: 'Рязань', built_to: 2022)

    broken_year = payload.merge('fields' => payload['fields'].merge('built_to' => 3000))
    result = described_class.call(broken_year)

    expect(result.status).to eq(:invalid)
    expect(ZhkFact.where(field: 'built_to').count).to eq(0)
  end

  it 'отвергает fields пустым массивом вместо необработанного исключения' do
    # Array#slice(*13 строк) — не Hash#slice: ArgumentError: wrong number
    # of arguments. .present? у [] — false, старая проверка это пропускала.
    broken = payload.merge('fields' => [])

    result = described_class.call(broken)

    expect(result.status).to eq(:invalid)
    expect(ResidentialComplex.count).to eq(0)
  end

  it 'отвергает fields пустой строкой вместо необработанного исключения' do
    broken = payload.merge('fields' => '')

    result = described_class.call(broken)

    expect(result.status).to eq(:invalid)
    expect(ResidentialComplex.count).to eq(0)
  end

  it 'принимает fields: null как «источник не нашёл полей», а не как поломку' do
    # "fields": null — самая естественная запись «полей нет». Ключ при
    # этом присутствует со значением nil: fetch('fields', {}) вернул бы
    # именно nil (не дефолт {}), и .slice упал бы NoMethodError.
    with_null_fields = payload.merge('fields' => nil)

    result = described_class.call(with_null_fields)

    expect(result.status).to eq(:created)
    complex = ResidentialComplex.unscoped.find(result.complex_id)
    expect(complex.developer).to be_nil
  end

  it 'отвергает нечисловой мусор в buildings_count вместо тихого приведения к 0' do
    garbage = payload.merge('fields' => payload['fields'].merge('buildings_count' => 'две'))

    result = described_class.call(garbage)

    expect(result.status).to eq(:invalid)
    expect(ResidentialComplex.count).to eq(0)
  end

  it 'отвергает отрицательный floors_min вместо тихого приведения к -5' do
    garbage = payload.merge('fields' => payload['fields'].merge('floors_min' => '-5'))

    result = described_class.call(garbage)

    expect(result.status).to eq(:invalid)
    expect(ResidentialComplex.count).to eq(0)
  end

  it 'отвергает buildings_count вне диапазона колонки вместо необработанного RangeError' do
    # numericality не знает о размере колонки в байтах (int4) — 99999999999
    # целое и положительное, но не влезает. Ошибка раньше вылезала бы
    # только на попытке записать значение (ActiveModel::RangeError).
    overflow = payload.merge('fields' => payload['fields'].merge('buildings_count' => 99_999_999_999))

    result = described_class.call(overflow)

    expect(result.status).to eq(:invalid)
    expect(ResidentialComplex.count).to eq(0)
  end

  it 'отвергает address_patterns строкой вместо повреждения массива при записи' do
    # Постгресовый array-тип не отвергает строку на присвоении — он молча
    # парсит её как литерал Postgres (кириллица режется побайтово и ломает
    # UTF-8, обычная строка остаётся строкой цифр). Настоящая ошибка
    # (PG::CharacterNotInRepertoire / malformed array literal) вылезает
    # только на INSERT.
    broken = payload.merge('fields' => payload['fields'].merge('address_patterns' => 'ул. Мира, 5'))

    result = described_class.call(broken)

    expect(result.status).to eq(:invalid)
    expect(ResidentialComplex.count).to eq(0)
  end

  it 'не гоняет пробный ResidentialComplex, если наблюдение уже отвергнуто более дешёвой причиной' do
    # probe.valid? реально ходит в базу (friendly_id-уникальность слага) —
    # платить эту цену за payload, отвергнутый структурной причиной
    # (город вне реестра), незачем.
    expect(ResidentialComplex).not_to receive(:new)

    described_class.call(payload.merge('city' => 'Атлантида'))
  end

  it 'не глотает RecordInvalid, который не про complex.save!' do
    # rescue InvalidComplex целится узко в save_complex! (обёртку вокруг
    # complex.save!), а не в любую запись внутри транзакции. RecordInvalid
    # из другого места (здесь — сымитирован в ZhkFact#update!) обязан
    # долететь наружу как есть.
    fake_record = ZhkFact.new
    allow_any_instance_of(ZhkFact).to receive(:update!) # rubocop:disable RSpec/AnyInstance
      .and_raise(ActiveRecord::RecordInvalid.new(fake_record))

    expect { described_class.call(payload) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(ResidentialComplex.count).to eq(0)
  end

  it 'строит и матчит черновик по одному и тому же имени, даже если fields несёт другое имя' do
    # payload['name'] и fields['name'] могут расходиться — если завести
    # черновик по одному, а матчить по другому, `FactApplier` (name — в
    # белом списке `FILLABLE`) переименует карточку сразу после создания,
    # и следующее наблюдение того же источника её не найдёт.
    renamed = payload.deep_dup
    renamed['fields']['name'] = 'Совсем другое имя'

    first = described_class.call(renamed)
    complex = ResidentialComplex.unscoped.find(first.complex_id)
    expect(complex.name).to eq('Совсем другое имя')

    second = described_class.call(renamed.merge('source' => 'other', 'external_id' => 'other:1'))

    expect(second.complex_id).to eq(first.complex_id)
    expect(ResidentialComplex.count).to eq(1)
  end
end
