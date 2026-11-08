# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ChatTools::Staff::MarketComparables do
  let!(:agent) do
    TelegramUser.create!(tg_user_id: 700_001, tg_username: 'irina', first_name: 'Ирина',
                         role: 'agent', is_manager: false, status: 'active')
  end

  let(:service_result) do
    {
      success: true,
      estimated_price: 4_350_000,
      min_price: 4_000_000,
      max_price: 4_700_000,
      price_per_sqm: 114_000,
      confidence_level: 0.72,
      tier: 2,
      low_coverage: false,
      websearch_count: 3,
      comparables: [
        { title: '1-комн. 38 м², Канищево', url: 'https://ryazan.cian.ru/sale/flat/294573918/',
          price: 4_350_000, price_per_sqm: 114_473, area: 38.0, rooms: 1,
          district: 'Канищево', source: 'external_listing', synthetic: false },
        { title: '1-комн. 40 м², ул. Ленина', url: nil,
          price: 4_600_000, price_per_sqm: 115_000, area: 40.0, rooms: 1,
          district: 'Центр', source: 'agency', synthetic: false },
        { title: 'Шаблон 1-комн.', url: nil,
          price: 4_200_000, price_per_sqm: 110_000, area: 38.0, rooms: 1,
          district: '', source: 'ai_synthesized', synthetic: true }
      ],
      ai_summary: 'Рынок стабилен.'
    }
  end

  before do
    allow(PropertyEvaluationService).to receive(:new).and_return(double(call: service_result))
    allow(Geocoding::AddressLookup).to receive(:call).and_return(nil)
    allow(Lead::Intake).to receive(:call)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('TAVILY_API_KEY').and_return('tvly-test-key')
    allow(ENV).to receive(:[]).with('FIRECRAWL_API_KEY').and_return('fc-test-key')
  end

  def call_tool(extra = {}, asked_by: agent)
    described_class.call(
      {
        'property_type' => 'apartment',
        'address'       => 'Рязань, ул. Островского, 27',
        'city'          => 'Рязань',
        'district'      => 'Канищево',
        'total_area'    => 38,
        'rooms'         => 1
      }.merge(extra),
      asked_by: asked_by
    )
  end

  describe '.schema' do
    it 'имя, обязательные поля и триггер-примеры в описании' do
      schema = described_class.schema
      expect(schema.dig(:function, :name)).to eq('market_comparables')
      expect(schema.dig(:function, :parameters, :required)).to include('property_type', 'address', 'total_area')

      description = schema.dig(:function, :description)
      expect(description).to include('Канищево')
      expect(description).to include('lookup_lead')
      expect(description).to include('kpi_for')
      expect(description).to match(/со ссылками/i)
    end
  end

  describe '.call — happy path' do
    it 'возвращает оценку, вилку, ₽/м², уверенность и low_coverage' do
      res = call_tool

      expect(res[:success]).to be(true)
      expect(res[:estimated_price]).to eq(4_350_000)
      expect(res[:min_price]).to eq(4_000_000)
      expect(res[:max_price]).to eq(4_700_000)
      expect(res[:price_per_sqm]).to eq(114_000)
      expect(res[:confidence_level]).to eq(0.72)
      expect(res[:low_coverage]).to be(false)
    end

    it 'comparables содержат url на объявление площадки, внешние первыми' do
      res = call_tool

      expect(res[:comparables].size).to eq(3)
      expect(res[:comparables].first[:url]).to eq('https://ryazan.cian.ru/sale/flat/294573918/')
      expect(res[:comparables].first[:price]).to eq(4_350_000)
      expect(res[:comparables].first[:area]).to eq(38.0)
      expect(res[:comparables].first[:district]).to eq('Канищево')
      expect(res[:comparables].map { |c| c[:url].present? }).to eq([true, false, false])
    end

    it 'внутренние comps (/properties/:id) НЕ помечаются external и идут в хвосте' do
      allow(PropertyEvaluationService).to receive(:new).and_return(
        double(call: service_result.merge(comparables: [
          { title: 'Наш объект 1-комн.', url: '/properties/42',
            price: 4_100_000, price_per_sqm: 107_000, area: 38.0, rooms: 1,
            district: 'Канищево', source: 'agency', synthetic: false },
          { title: 'ЦИАН 1-комн.', url: 'https://ryazan.cian.ru/sale/flat/294573918/',
            price: 4_350_000, price_per_sqm: 114_473, area: 38.0, rooms: 1,
            district: 'Канищево', source: 'external_listing', synthetic: false }
        ]))
      )

      res = call_tool

      expect(res[:comparables].map { |c| c[:url] })
        .to eq(['https://ryazan.cian.ru/sale/flat/294573918/', '/properties/42'])
      expect(res[:comparables].map { |c| c[:external] }).to eq([true, false])
    end

    it 'сохраняет PropertyValuation с metadata source=work_bot и id сотрудника' do
      call_tool

      pv = PropertyValuation.order(:id).last
      expect(pv.metadata['source']).to eq('work_bot')
      expect(pv.metadata['asked_by_id']).to eq(agent.id)
      expect(pv.metadata['asked_by_tg_user_id']).to eq(agent.tg_user_id)
      expect(pv.metadata['tool']).to eq('market_comparables')
      expect(pv.status).to eq('completed')
      expect(pv.user_agent).to eq('work_bot')
    end

    it 'НЕ пушит staff-запрос в work_bot intake (не лид)' do
      call_tool
      expect(Lead::Intake).not_to have_received(:call)
    end
  end

  describe '.call — честный дегрейд' do
    it 'без ключей Tavily/Firecrawl: оценка есть, websearch=unavailable + note' do
      allow(ENV).to receive(:[]).with('TAVILY_API_KEY').and_return(nil)

      res = call_tool

      expect(res[:success]).to be(true)
      expect(res[:websearch]).to eq('unavailable')
      expect(res[:market_note]).to include('Поиск по площадкам недоступен')
    end

    it 'с ключами и свежими объявлениями: websearch=ok, note нет' do
      res = call_tool

      expect(res[:websearch]).to eq('ok')
      expect(res[:market_note]).to be_nil
    end

    it 'поиск не дал объявлений (ошибка/пусто): честный configured, а не ок' do
      allow(PropertyEvaluationService).to receive(:new).and_return(
        double(call: service_result.merge(websearch_count: 0))
      )

      res = call_tool

      expect(res[:success]).to be(true)
      expect(res[:websearch]).to eq('configured')
      expect(res[:market_note]).to include('не получены')
    end

    it 'для аренды: честный websearch=skipped_rent, а не ложный ok' do
      res = call_tool({ 'deal_type' => 'rent' })

      expect(res[:success]).to be(true)
      expect(res[:websearch]).to eq('skipped_rent')
      expect(res[:market_note]).to include('аренды')
    end

    it 'участок: площадь в сотках уходит И в land_area, И в total_area (comp-пайплайн)' do
      res = call_tool({ 'property_type' => 'land', 'total_area' => 8, 'rooms' => nil })

      expect(res[:success]).to be(true)
      pv = PropertyValuation.order(:id).last
      expect(pv.property_type).to eq('land')
      expect(pv.land_area).to eq(8)
      expect(pv.total_area).to eq(8)
    end

    it 'сервис вернул failure — valuation failed + структурный error' do
      allow(PropertyEvaluationService).to receive(:new)
        .and_return(double(call: { success: false, error: 'Недостаточно данных для оценки' }))

      res = call_tool

      expect(res[:error]).to eq('evaluation_failed')
      expect(PropertyValuation.order(:id).last.status).to eq('failed')
    end
  end

  describe '.call — валидация' do
    it 'без asked_by — caller_unknown' do
      res = described_class.call({ 'property_type' => 'apartment', 'address' => 'Рязань, ул. Островского, 27', 'total_area' => 38 })
      expect(res[:error]).to eq('caller_unknown')
    end

    it 'без обязательных полей — missing_fields' do
      res = described_class.call({ 'property_type' => 'apartment' }, asked_by: agent)
      expect(res[:error]).to eq('missing_fields')
      expect(res[:missing]).to include('address', 'total_area')
    end
  end

  describe 'security boundary (staff-only)' do
    it 'зарегистрирован в ChatTools::Staff::Registry::HANDLERS' do
      expect(ChatTools::Staff::Registry::HANDLERS).to have_key('market_comparables')
    end

    it 'клиентский ChatTools::Registry его НЕ содержит' do
      expect(ChatTools::Registry::HANDLERS).not_to have_key('market_comparables')
      expect(ChatTools::Registry::HANDLERS.keys).not_to include('market_comparables')
    end

    it 'диспатчится через staff registry с asked_by' do
      res = ChatTools::Staff::Registry.call(
        'market_comparables',
        { 'property_type' => 'apartment', 'address' => 'Рязань, ул. Островского, 27', 'total_area' => 38 },
        asked_by: agent
      )
      expect(res[:success]).to be(true)
    end
  end

  # Регрессионный интеграционный тест ревью Kimi (PR #184): без мока
  # PropertyEvaluationService — реальный ComparableFinder должен пропустить
  # внешний land-аналог (area-band по соткам) до ответа тула.
  describe 'интеграция: реальный PropertyEvaluationService' do
    let!(:land_listing) do
      create(:external_listing,
             source: 'cian', url: 'https://ryazan.cian.ru/sale/land/777/',
             property_type: 'land', deal_type: 'sale',
             city: 'Рязань', district: 'Канищево',
             area: 8.0, rooms: 0, price: 1_800_000,
             fetched_at: Time.current, closed_at: nil)
    end

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
      allow(Valuations::AiCompFilter).to receive(:new) do |_v, candidates|
        instance_double(Valuations::AiCompFilter, call: candidates)
      end
    end

    it 'участок: внешний land-аналог реально попадает в ответ' do
      res = described_class.call(
        {
          'property_type' => 'land',
          'address'       => 'Рязань, Канищево, Солотчинское шоссе, 1',
          'city'          => 'Рязань',
          'district'      => 'Канищево',
          'total_area'    => 8
        },
        asked_by: agent
      )

      expect(res[:success]).to be(true)
      urls = res[:comparables].map { |c| c[:url] }
      expect(urls).to include('https://ryazan.cian.ru/sale/land/777/')
    end
  end
end
