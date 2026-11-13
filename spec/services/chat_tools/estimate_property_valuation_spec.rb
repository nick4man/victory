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

  describe 'тест-режим чат-бота (issue #214)' do
    after { Thread.current[:lead_test_mode] = false }

    it 'probe-прогон: valuation создаётся с metadata["test"]=true' do
      Thread.current[:lead_test_mode] = true
      call_tool

      expect(PropertyValuation.order(:id).last.metadata['test']).to be(true)
    end

    it 'боевой прогон: тест-флага в metadata нет' do
      call_tool

      expect(PropertyValuation.order(:id).last.metadata).not_to have_key('test')
    end

    it 'test? true только при metadata["test"]=true' do
      pv = PropertyValuation.new(metadata: { 'test' => true })
      expect(pv).to be_test
      expect(PropertyValuation.new(metadata: {})).not_to be_test
      expect(PropertyValuation.new(metadata: nil)).not_to be_test
    end

    it 'push_to_work_bot прокидывает тест-флаг в payload Lead::Intake' do
      pv = PropertyValuation.new(metadata: { 'test' => true }, token: 'tok-1')
      allow(pv).to receive_messages(
        full_name: 'Тест', estimated_price_formatted: '5 400 000 ₽', test?: true
      )

      expect(Lead::Intake).to receive(:call) do |args|
        expect(args[:payload][:test]).to be(true)
        Lead::Intake::Result.new(success: true)
      end
      pv.send(:push_to_work_bot)
    end

    it 'боевой valuation шлёт test: false — маршрут не меняется' do
      pv = PropertyValuation.new(metadata: {}, token: 'tok-2')
      allow(pv).to receive_messages(
        full_name: 'Клиент', estimated_price_formatted: '5 400 000 ₽', test?: false
      )

      expect(Lead::Intake).to receive(:call) do |args|
        expect(args[:payload][:test]).to be(false)
        Lead::Intake::Result.new(success: true)
      end
      pv.send(:push_to_work_bot)
    end
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

  describe '.schema' do
    it 'объясняет боту, как озвучивать низкое покрытие' do
      description = described_class.schema.dig(:function, :description)

      expect(description).to include('low_coverage')
      expect(description).to match(/ориентировочн/i)
    end
  end
end
