# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Valuations::SimilarValuationsFinder do
  let(:query_vector) { [1.0] + Array.new(767, 0.0) }
  let(:near_vector)  { [0.99, 0.14] + Array.new(766, 0.0) }
  let(:far_vector)   { [0.0, 1.0] + Array.new(766, 0.0) }

  subject(:subject_valuation) do
    # persisted: шаблон эмбеддинга читает created_at
    PropertyValuation.create!(
      property_type: 'apartment', deal_type: 'sale', audit_mode: 'express',
      status: 'pending',
      address: 'г. Рязань, ул. Subject, д. 1', city: 'Рязань',
      latitude: 54.6292, longitude: 39.7417,
      total_area: 54.0, rooms: 2, evaluation_data: {}
    )
  end

  before do
    allow(Embedding::GoogleClient).to receive(:new)
      .and_return(instance_double(Embedding::GoogleClient, embed: query_vector))
  end

  def seed_valuation!(price:, city: 'Рязань', deal_type: 'sale', status: 'completed',
                      staff_test: false, vector: near_vector, source: 'work_bot')
    v = PropertyValuation.create!(
      property_type: 'apartment', deal_type: deal_type, audit_mode: 'express',
      status: status, staff_test: staff_test,
      address: "г. #{city}, ул. Seed, д. #{PropertyValuation.count + 1}",
      city: city, latitude: 54.6292, longitude: 39.7417,
      total_area: 50.0, rooms: 2,
      estimated_price: price, evaluation_data: {},
      metadata: source ? { 'source' => source } : {}
    )
    PropertyValuationEmbedding.create!(
      property_valuation: v,
      content_hash: Digest::SHA256.hexdigest("seed-#{v.id}"),
      content_text: "seed #{v.id}",
      embedding: vector,
      embedded_at: Time.current
    )
    v
  end

  it 'агрегирует похожие оценки того же города и типа сделки (медиана/min/max)' do
    seed_valuation!(price: 4_000_000)
    seed_valuation!(price: 4_200_000)
    seed_valuation!(price: 5_000_000)

    result = described_class.call(subject_valuation)

    expect(result[:count]).to eq(3)
    expect(result[:median_price]).to eq(4_200_000)
    expect(result[:min_price]).to eq(4_000_000)
    expect(result[:max_price]).to eq(5_000_000)
    expect(result[:low_coverage]).to be(false)
  end

  it 'медиана при чётном N — среднее двух средних' do
    seed_valuation!(price: 4_000_000)
    seed_valuation!(price: 4_200_000)
    seed_valuation!(price: 5_000_000)
    seed_valuation!(price: 5_200_000)

    result = described_class.call(subject_valuation)

    expect(result[:count]).to eq(4)
    expect(result[:median_price]).to eq(4_600_000)
  end

  it 'не подмешивает оценки другого города, аренду, staff_test, незавершённые и слабо-похожие' do
    seed_valuation!(price: 4_000_000)
    seed_valuation!(price: 4_200_000)
    seed_valuation!(price: 4_400_000)
    seed_valuation!(price: 10_000_000, city: 'Москва')
    seed_valuation!(price: 30_000, deal_type: 'rent')
    seed_valuation!(price: 1_000_000, staff_test: true)
    seed_valuation!(price: 2_000_000, status: 'pending')
    seed_valuation!(price: 3_000_000, vector: far_vector)

    result = described_class.call(subject_valuation)

    expect(result[:count]).to eq(3)
    expect(result[:min_price]).to eq(4_000_000)
    expect(result[:max_price]).to eq(4_400_000)
  end

  it 'клиентские express-оценки не попадают в корпус — только work_bot (ревью #206)' do
    seed_valuation!(price: 4_000_000)
    seed_valuation!(price: 4_200_000)
    seed_valuation!(price: 4_400_000)
    # клиентские оценки (сайт/чат-бот): source отсутствует или другой —
    # «оценками наших специалистов» их называть нельзя
    seed_valuation!(price: 9_000_000, source: nil)
    seed_valuation!(price: 8_000_000, source: 'site')

    result = described_class.call(subject_valuation)

    expect(result[:count]).to eq(3)
    expect(result[:min_price]).to eq(4_000_000)
    expect(result[:max_price]).to eq(4_400_000)
  end

  it 'ближайшие клиентские оценки не вытесняют staff-строки до LIMIT (фильтр в SQL)' do
    # Клиентская оценка векторно БЛИЖЕ всех (query_vector=[1,0,…]) — без
    # SQL-фильтра она съела бы слот в LIMIT 20 и дала бы ложный low_coverage.
    near_client = [1.0] + Array.new(767, 0.0)
    seed_valuation!(price: 9_000_000, source: nil, vector: near_client)
    seed_valuation!(price: 4_000_000)
    seed_valuation!(price: 4_200_000)
    seed_valuation!(price: 4_400_000)

    result = described_class.call(subject_valuation)

    expect(result[:count]).to eq(3)
    expect(result[:low_coverage]).to be(false)
  end

  it 'сравнение городов case-insensitive и с префиксом «г.»' do
    seed_valuation!(price: 4_000_000, city: 'г. рязань')
    seed_valuation!(price: 4_200_000)
    seed_valuation!(price: 4_400_000)

    result = described_class.call(subject_valuation)

    expect(result[:count]).to eq(3)
  end

  it 'пустой корпус → count 0 и low_coverage' do
    result = described_class.call(subject_valuation)

    expect(result[:count]).to eq(0)
    expect(result[:median_price]).to be_nil
    expect(result[:low_coverage]).to be(true)
  end

  it 'N < 3 → low_coverage: true' do
    seed_valuation!(price: 4_000_000)
    seed_valuation!(price: 4_200_000)

    result = described_class.call(subject_valuation)

    expect(result[:count]).to eq(2)
    expect(result[:low_coverage]).to be(true)
  end

  it 'пустой город subject → fail-close: ноль результатов без вызова эмбеддера' do
    subject_valuation.city = ''

    result = described_class.call(subject_valuation)

    expect(result[:count]).to eq(0)
    expect(Embedding::GoogleClient).not_to have_received(:new)
  end

  it 'ошибка эмбеддера → nil (вызывающий деградирует до express-only)' do
    allow(Embedding::GoogleClient).to receive(:new)
      .and_raise(Embedding::GoogleClient::Error, 'rate limit')

    expect(described_class.call(subject_valuation)).to be_nil
  end

  it 'не возвращает поштучных данных оценок — только агрегат' do
    seed_valuation!(price: 4_000_000)
    seed_valuation!(price: 4_200_000)
    seed_valuation!(price: 4_400_000)

    result = described_class.call(subject_valuation)

    expect(result.keys).to match_array(%i[count median_price min_price max_price low_coverage])
  end
end
