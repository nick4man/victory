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
