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
    described_class.call(payload)
    complex_id = ResidentialComplex.find_by(name: 'Скобелев').id

    second = described_class.call(payload)

    expect(second.status).to eq(:duplicate)
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

  it 'отвергает наблюдение без источника или имени' do
    expect(described_class.call(payload.except('name')).status).to eq(:invalid)
  end

  it 'отвергает наблюдение с городом вне реестра' do
    expect(described_class.call(payload.merge('city' => 'Атлантида')).status).to eq(:invalid)
  end

  it 'отвергает наблюдение с битой ценой' do
    broken = payload.merge('price' => { 'kind' => 'from', 'price_per_sqm' => -5 })

    expect(described_class.call(broken).status).to eq(:invalid)
  end

  it 'ничего не оставляет после себя при исключении в середине применения' do
    allow(Zhk::FactApplier).to receive(:apply).and_raise('boom')

    expect { described_class.call(payload) }.to raise_error('boom')

    expect(ZhkObservation.count).to eq(0)
    expect(ZhkFact.count).to eq(0)
    expect(ZhkPricePoint.count).to eq(0)
    expect(ResidentialComplex.count).to eq(0)
  end
end
