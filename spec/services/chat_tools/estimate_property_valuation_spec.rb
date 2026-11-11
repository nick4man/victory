# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ChatTools::EstimatePropertyValuation do
  let(:service_result) do
    {
      success: true,
      estimated_price: 5_400_000,
      min_price: 4_968_000,
      max_price: 5_832_000,
      price_per_sqm: 100_000,
      confidence_level: 0.65,
      tier: 4,
      comparables: [],
      ai_summary: '',
      low_coverage: true
    }
  end

  before do
    allow(PropertyEvaluationService).to receive(:new).and_return(double(call: service_result))
    allow(Geocoding::AddressLookup).to receive(:call).and_return(nil)
    # По умолчанию semantic-поиск похожих оценок выключен — иначе каждый
    # вызов тула пошёл бы в Embedding::GoogleClient (WebMock).
    allow(Valuations::SimilarValuationsFinder).to receive(:call).and_return(nil)
  end

  def call_tool
    described_class.call(
      'property_type' => 'apartment',
      'address' => 'г. Рязань, ул. Тестовая, д. 1',
      'city' => 'Рязань',
      'total_area' => 54
    )
  end

  it 'прокидывает признак low_coverage из сервиса оценки' do
    expect(call_tool[:low_coverage]).to be(true)
  end

  it 'передаёт low_coverage: false когда локальные аналоги есть' do
    service_result[:low_coverage] = false

    expect(call_tool[:low_coverage]).to be(false)
  end

  it 'при завершении через update_columns ставит EmbedPropertyValuationJob явно' do
    expect { call_tool }.to have_enqueued_job(EmbedPropertyValuationJob)
  end

  it 'НЕ пушит LeadEvent при создании оценки — анонс один, из Inquiry (ревью #206)' do
    expect { call_tool }.not_to change(LeadEvent, :count)
  end

  describe 'участок (land) — нормализация площади и реальный PropertyEvaluationService' do
    before do
      allow(PropertyEvaluationService).to receive(:new).and_call_original
      allow(Valuations::WebsearchCompFinder).to receive(:new)
        .and_return(instance_double(Valuations::WebsearchCompFinder, call: 0))
      allow(Valuations::SitemapCompFinder).to receive(:new)
        .and_return(instance_double(Valuations::SitemapCompFinder, call: 0))
      allow(Valuations::SemanticCompFinder).to receive(:call).and_return([])
      allow(Valuations::CrossCityAdapter).to receive(:call).and_return([])
      allow(Valuations::AiSyntheticComps).to receive(:call).and_return([])
      allow(Valuations::AiExplainer).to receive(:new)
        .and_return(instance_double(Valuations::AiExplainer, call: nil))
    end

    it 'сохраняет land_area в сотках, total_area в м², завершает оценку и формирует полный текст эмбеддинга' do
      res = nil
      expect do
        res = described_class.call(
          'property_type' => 'land',
          'address'       => 'г. Рязань, Канищево, Солотчинское шоссе, 1',
          'city'          => 'Рязань',
          'district'      => 'Канищево',
          'total_area'    => 8
        )
      end.to have_enqueued_job(EmbedPropertyValuationJob)

      expect(res[:success]).to be(true)
      pv = PropertyValuation.find_by!(token: res[:token])
      expect(pv.status).to eq('completed')
      expect(pv.land_area).to eq(8)
      expect(pv.total_area).to eq(800)

      tpl = Embedding::PropertyValuationTextTemplate.build(pv)
      expect(tpl).to include('Площадь участка: 8.0 сот.')
      expect(tpl).to include('Цена за м²:')
    end
  end

  describe 'ориентир по похожим оценкам специалистов (issue #176)' do
    let(:query_vector) { [1.0] + Array.new(767, 0.0) }
    let(:near_vector)  { [0.99, 0.14] + Array.new(766, 0.0) }
    let(:far_vector)   { [0.0, 1.0] + Array.new(766, 0.0) }
    let(:embed_texts)  { [] }

    before do
      service_result[:low_coverage] = false
      allow(Valuations::SimilarValuationsFinder).to receive(:call).and_call_original
      google = instance_double(Embedding::GoogleClient)
      allow(google).to receive(:embed) do |text|
        embed_texts << text
        query_vector
      end
      allow(Embedding::GoogleClient).to receive(:new).and_return(google)
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

    it 'возвращает только агрегат (count/медиана/min/max) — поштучных данных чужих оценок нет' do
      seed_valuation!(price: 4_000_000)
      seed_valuation!(price: 4_200_000)
      seed_valuation!(price: 5_000_000)
      # фильтруются: другой город / аренда / staff_test / cosine ниже порога
      seed_valuation!(price: 10_000_000, city: 'Москва')
      seed_valuation!(price: 30_000, deal_type: 'rent')
      seed_valuation!(price: 1_000_000, staff_test: true)
      seed_valuation!(price: 2_000_000, vector: far_vector)

      res = call_tool

      expect(res[:similar_valuations_count]).to eq(3)
      expect(res[:similar_median_price]).to eq(4_200_000)
      expect(res[:similar_min_price]).to eq(4_000_000)
      expect(res[:similar_max_price]).to eq(5_000_000)
      expect(res[:low_coverage]).to be(false)
      # наружу не утекают адреса/детали чужих оценок
      expect(res.to_s).not_to include('Москва')
      expect(res.to_s).not_to include('Seed')
    end

    it 'сохраняет агрегат в evaluation_data оценки — для передачи специалисту' do
      seed_valuation!(price: 4_000_000)
      seed_valuation!(price: 4_200_000)
      seed_valuation!(price: 5_000_000)

      res = call_tool

      pv = PropertyValuation.find_by!(token: res[:token])
      similar = pv.evaluation_data['similar_valuations']
      expect(similar['count']).to eq(3)
      expect(similar['median_price']).to eq(4_200_000)
      expect(similar['low_coverage']).to be(false)
    end

    it 'query-эмбеддинг строится по представлению С записанным результатом оценки (блокер ревью #206)' do
      call_tool

      # Шаблон эмбеддинга включает итоговую цену/вилку/число аналогов — иначе
      # cosine считался бы между разными представлениями. Пробелы нормализуем
      # (ru-локаль number_to_currency может отдавать nbsp).
      query_text = embed_texts.join("\n").gsub(/\s+/, '')
      expect(query_text).to include('Итоговаяценаоценки:5400000')
    end

    it 'N < 3 → low_coverage: true, ценовые similar_* поля nil (fail-close), фолбэк на экспресс-оценку' do
      seed_valuation!(price: 4_000_000)

      res = call_tool

      expect(res[:similar_valuations_count]).to eq(1)
      expect(res[:low_coverage]).to be(true)
      # fail-close на уровне данных (ревью #206): N = 1 — это точная цена
      # одной чужой оценки, наружу она не отдаётся
      expect(res[:similar_median_price]).to be_nil
      expect(res[:similar_min_price]).to be_nil
      expect(res[:similar_max_price]).to be_nil
      # экспресс-оценка на месте — бот опирается на неё
      expect(res[:estimated_price]).to eq(5_400_000)
    end

    it 'клиентские express-оценки не смешиваются с оценками специалистов' do
      seed_valuation!(price: 4_000_000)
      seed_valuation!(price: 4_200_000)
      seed_valuation!(price: 4_400_000)
      seed_valuation!(price: 9_000_000, source: nil)

      res = call_tool

      expect(res[:similar_valuations_count]).to eq(3)
      expect(res[:similar_median_price]).to eq(4_200_000)
    end

    it 'query-вектор строится ПОСЛЕ записи результата оценки в pv (ревью #206)' do
      # Шаблон эмбеддинга включает цену/вилку/₽-за-м²/число аналогов — finder
      # должен видеть результат, иначе cosine считается между разными
      # представлениями.
      received = nil
      allow(Valuations::SimilarValuationsFinder).to receive(:call) do |pv|
        received = pv
        nil
      end

      call_tool

      expect(received.estimated_price).to eq(5_400_000)
      expect(received.min_price).to eq(4_968_000)
      expect(received.max_price).to eq(5_832_000)
      expect(received.evaluation_data).to include('estimated_price')
    end

    it 'пустой корпус похожих оценок → count 0, low_coverage: true' do
      res = call_tool

      expect(res[:similar_valuations_count]).to eq(0)
      expect(res[:low_coverage]).to be(true)
      expect(res[:success]).to be(true)
    end

    it 'инфраструктурный сбой semantic-поиска → express-only ответ' do
      allow(Valuations::SimilarValuationsFinder).to receive(:call).and_return(nil)

      res = call_tool

      expect(res[:success]).to be(true)
      expect(res[:similar_valuations_count]).to be_nil
      expect(res[:low_coverage]).to be(false)
    end
  end

  describe '.schema' do
    it 'объясняет боту, как озвучивать низкое покрытие' do
      description = described_class.schema.dig(:function, :description)

      expect(description).to include('low_coverage')
      expect(description).to match(/ориентировочн/i)
    end

    it 'объясняет боту про ориентир по оценкам специалистов и передачу специалисту' do
      description = described_class.schema.dig(:function, :description)

      expect(description).to include('similar_valuations_count')
      expect(description).to match(/оценкам наших специалистов/)
      expect(description).to include('request_specialist_evaluation')
    end
  end
end
