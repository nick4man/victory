# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Valuations::SemanticCompFinder do
  # Subject: продажа 2-комн 54 м² в Рязани. Координаты Рязани ~54.6292/39.7187.

  let(:valuation) do
    PropertyValuation.new(
      property_type: 'apartment', deal_type: 'sale', audit_mode: 'express',
      address: 'г. Рязань, ул. Тестовая, д. 1', city: 'Рязань',
      total_area: 54, rooms: 2, status: 'pending',
      latitude: 54.6292, longitude: 39.7187
    )
  end

  def property_double(city: 'Рязань', deal_type: 'sale', coords: [54.63, 39.72])
    instance_double(
      Property,
      price: 5_400_000, area: 54.0, rooms: 2, district: 'Канищево',
      city: city, deal_type: deal_type,
      latitude: coords.first, longitude: coords.last,
      title: '2-комн. квартира, 54 м²', slug: 'test-property'
    )
  end

  def embedding_double(property, distance: 0.1)
    double('embedding', property: property, neighbor_distance: distance)
  end

  def stub_nearest_neighbors(embeddings)
    relation = double('relation')
    allow(relation).to receive_messages(includes: relation, limit: relation, to_a: embeddings)
    allow(PropertyEmbedding).to receive(:nearest_neighbors).and_return(relation)
  end

  before do
    allow_any_instance_of(described_class).to receive(:embed_text)
      .and_return(Array.new(768, 0.1))
  end

  it 'включает ближний объект того же города и типа сделки' do
    stub_nearest_neighbors([embedding_double(property_double)])

    expect(described_class.call(valuation).size).to eq(1)
  end

  it 'отбрасывает объект с другим deal_type (аренда среди продаж)' do
    stub_nearest_neighbors([embedding_double(property_double(deal_type: 'rent'))])

    expect(described_class.call(valuation)).to be_empty
  end

  it 'отбрасывает объект из другого города' do
    stub_nearest_neighbors([embedding_double(property_double(city: 'Санкт-Петербург', coords: [59.94, 30.31]))])

    expect(described_class.call(valuation)).to be_empty
  end

  it 'отбрасывает объект того же города дальше радиуса 50 км' do
    # ~175 км от Рязани, city совпадает — должен отсечься по расстоянию
    stub_nearest_neighbors([embedding_double(property_double(coords: [55.75, 37.61]))])

    expect(described_class.call(valuation)).to be_empty
  end

  it 'оставляет объект без координат при совпадении города' do
    stub_nearest_neighbors([embedding_double(property_double(coords: [nil, nil]))])

    expect(described_class.call(valuation).size).to eq(1)
  end

  it 'не фильтрует по городу, если город subject неизвестен' do
    valuation.city = nil
    stub_nearest_neighbors([embedding_double(property_double(city: 'Санкт-Петербург', coords: [nil, nil]))])

    expect(described_class.call(valuation).size).to eq(1)
  end
end
