# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Valuations::WebsearchCompFinder do
  let(:valuation) do
    PropertyValuation.new(
      property_type: 'apartment', deal_type: 'sale', audit_mode: 'express',
      address: 'г. Санкт-Петербург, ул. Осипенко, д. 3',
      city: 'Санкт-Петербург', district: 'Красногвардейский',
      total_area: 26.6, rooms: 1, status: 'pending'
    )
  end

  let(:finder) { described_class.new(valuation) }

  describe '#cached_count — единицы band для участков (ревью Kimi, PR #184)' do
    let(:land_valuation) do
      PropertyValuation.new(
        property_type: 'land', deal_type: 'sale', audit_mode: 'express',
        address: 'г. Рязань, Канищево', city: 'Рязань', district: 'Канищево',
        total_area: 800, land_area: 8, rooms: 0, status: 'pending'
      )
    end
    let(:land_finder) { described_class.new(land_valuation) }

    it 'band кэша для участка — в сотках (land_area), как площади ExternalListing' do
      expect(land_finder.send(:area_bracket_min)).to eq(6.0)
      expect(land_finder.send(:area_bracket_max)).to eq(10.0)
    end

    it 'band для квартиры — в м² по total_area (прежнее поведение)' do
      expect(finder.send(:area_bracket_min)).to eq(20.0)
      expect(finder.send(:area_bracket_max)).to eq(33.3)
    end
  end

  def parsed(city: 'Санкт-Петербург', url: 'https://cian.ru/offer/123456')
    {
      source_url: url,
      title: 'Студия, 26,6 м²',
      price: 5_400_000,
      area: 26.6,
      rooms: 1,
      floor: 11,
      total_floors: 17,
      building_year: 2005,
      condition: 'good',
      district: 'Красногвардейский',
      address: 'ул. Осипенко, д. 3',
      city: city
    }
  end

  describe '#persist — атрибуция города' do
    it 'сохраняет город, подтверждённый карточкой' do
      finder.send(:persist, [parsed])

      record = ExternalListing.find_by!(source: 'cian', source_id: '123456')
      expect(record.city).to eq('Санкт-Петербург')
    end

    it 'отклоняет объявление из чужого города, даже если subject его запрашивал' do
      count = finder.send(:persist, [parsed(city: 'Рязань')])

      expect(count).to eq(0)
      expect(ExternalListing.where(source_id: '123456')).not_to exist
    end

    it 'не перезаписывает подтверждённый город существующей записи при subject без города' do
      create(:external_listing, source: 'cian', source_id: '123456', city: 'Рязань')
      valuation_without_city = PropertyValuation.new(
        property_type: 'apartment', deal_type: 'sale', audit_mode: 'express',
        address: 'ул. Безгородная, д. 1', city: nil,
        total_area: 26.6, rooms: 1, status: 'pending'
      )

      count = described_class.new(valuation_without_city).send(:persist, [parsed(city: '')])

      expect(count).to eq(1)
      expect(ExternalListing.find_by!(source: 'cian', source_id: '123456').city).to eq('Рязань')
    end

    it 'отклоняет новую запись, если карточка город не подтверждает (fail-close)' do
      count = finder.send(:persist, [parsed(city: '')])

      expect(count).to eq(0)
      expect(ExternalListing.where(source: 'cian', source_id: '123456')).not_to exist
    end

    it 'отклоняет legacy-запись с NULL city при persist без подтверждённого города' do
      create(:external_listing, source: 'cian', source_id: '123456', city: nil)

      count = finder.send(:persist, [parsed(city: '')])

      expect(count).to eq(0)
      expect(ExternalListing.find_by!(source: 'cian', source_id: '123456').city).to be_nil
    end

    it 'нормализует префикс «г.» у города из карточки' do
      finder.send(:persist, [parsed(city: 'г. Санкт-Петербург')])

      expect(ExternalListing.find_by!(source: 'cian', source_id: '123456').city)
        .to eq('Санкт-Петербург')
    end
  end

  describe '#build_query' do
    it 'для участка ищет сотки, а не «м²» (ревью Kimi, PR #184)' do
      land_valuation = PropertyValuation.new(
        property_type: 'land', deal_type: 'sale', audit_mode: 'express',
        address: 'г. Рязань, Канищево', city: 'Рязань',
        land_area: 8, total_area: 8, status: 'pending'
      )

      query = described_class.new(land_valuation).send(:build_query)

      expect(query).to include('участок 8 соток')
      expect(query).not_to include('м²')
    end

    it 'для квартиры площадь остаётся в м²' do
      expect(finder.send(:build_query)).to include("#{valuation.total_area.to_i} м²")
    end
  end

  describe '#call — rent-оценки' do
    it 'не запускает pipeline: поиск жёстко ищет продажу, а не аренду (issue #172)' do
      rent_valuation = PropertyValuation.new(
        property_type: 'apartment', deal_type: 'rent', audit_mode: 'express',
        address: 'г. Рязань, ул. Ленина, д. 1', city: 'Рязань',
        total_area: 54, rooms: 2, status: 'pending'
      )
      rent_finder = described_class.new(rent_valuation)
      allow(rent_finder).to receive(:enabled?).and_return(true)

      expect(rent_finder.call).to eq(0)
    end
  end

  describe '#call — cache hit' do
    before { allow(finder).to receive(:enabled?).and_return(true) }

    def fresh_local(city:)
      create(:external_listing,
             property_type: 'flat', deal_type: 'sale', city: city,
             district: 'Красногвардейский', area: 26.6,
             fetched_at: Time.current, closed_at: nil)
    end

    it 'бьётся по slug-типу (flat, не apartment) и городу без платного поиска (PR #178)' do
      5.times { fresh_local(city: 'Санкт-Петербург') }
      allow(finder).to receive(:tavily_search).and_raise('платный поиск не должен вызываться')

      expect(finder.call).to eq(5)
    end

    it 'не бьётся по записям другого города — свежий поиск запускается' do
      5.times { fresh_local(city: 'Рязань') }
      allow(finder).to receive(:tavily_search).and_return([])

      expect(finder.call).to eq(0)
    end
  end

  # === Eval-фикстуры (issue #173) ===
  # Записанные markdown-страницы реальных объявлений (≥3 площадки) +
  # ожидаемые поля. LLM-парсинг стабится записанными результатами —
  # проверяем downstream-пайплайн: поля, маппинг доменов, отбрасывание
  # чужого города и аренды. Сеть закрыта WebMock, реальных вызовов нет.
  describe 'eval-фикстуры' do
    FIXTURE_DIR = Rails.root.join('spec/fixtures/valuations/websearch')
    EVAL = JSON.parse(File.read(FIXTURE_DIR.join('expected.json'))).freeze

    let(:tavily_client) { instance_double(Tavily::Client) }
    let(:firecrawl_client) { instance_double(Firecrawl::Client) }
    let(:ryazan_finder) do
      described_class.new(
        PropertyValuation.new(
          property_type: 'apartment', deal_type: 'sale', audit_mode: 'express',
          address: 'г. Рязань, ул. Соборная, д. 12', city: 'Рязань',
          district: 'Канищево', total_area: 54, rooms: 2, status: 'pending'
        )
      )
    end

    before do
      allow(Tavily::Client).to receive(:new).and_return(tavily_client)
      allow(Firecrawl::Client).to receive(:new).and_return(firecrawl_client)
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('TAVILY_API_KEY').and_return('tvly-test-key')
      allow(ENV).to receive(:[]).with('FIRECRAWL_API_KEY').and_return('fc-test-key')

      url_to_json = EVAL.to_h { |_, e| [e['url'], e['llm_result'].to_json] }
      fake_llm = Class.new do
        define_method(:initialize) { |map| @map = map }
        define_method(:complete) do |messages, **_opts|
          url = messages.last[:content].to_s[/\AURL: (\S+)/, 1]
          { content: @map.fetch(url, '{}'), model: 'eval-stub' }
        end
      end
      allow(Llm::OmniClient).to receive(:new).and_return(fake_llm.new(url_to_json))

      md_by_url = EVAL.to_h { |key, e| [e['url'], FIXTURE_DIR.join("#{key}.md").read] }
      allow(firecrawl_client).to receive(:scrape) { |url| md_by_url[url] }
    end

    def stub_eval_tavily(urls)
      results = urls.map { |u| { title: "listing #{u}", url: u, content: 'snippet', score: 0.9 } }
      allow(tavily_client).to receive(:search).and_return(results)
    end

    it 'PARSE_SYSTEM_PROMPT требует все ключевые поля, включая город' do
      %w[price area rooms city].each do |key|
        expect(described_class::PARSE_SYSTEM_PROMPT).to include(key)
      end
    end

    it 'markdown содержит ожидаемые «сырые» значения (страж дрейфа фикстур)' do
      EVAL.each do |key, entry|
        md = FIXTURE_DIR.join("#{key}.md").read
        expect(md).to include(entry.dig('raw_checks', 'price_str')), "price drift in #{key}"
        expect(md).to include(entry.dig('raw_checks', 'area_str')), "area drift in #{key}"
      end
    end

    it 'покрывает 4 площадки: ЦИАН, Avito, Я.Недвижимость, Домклик' do
      hosts = EVAL.values.map { |e| URI(e['url']).host }
      expect(hosts).to include(a_string_matching(/cian\.ru/))
      expect(hosts).to include(a_string_matching(/avito\.ru/))
      expect(hosts).to include(a_string_matching(/realty\.yandex|realty\.ya\.ru/))
      expect(hosts).to include(a_string_matching(/domclick\.ru/))
    end

    context 'полный пайплайн: 4 площадки Рязани + объявление другого города' do
      let(:good_keys) { %w[cian_sale_ryazan avito_sale_ryazan yandex_sale_ryazan domclick_sale_ryazan] }

      before { stub_eval_tavily(good_keys.map { |k| EVAL[k]['url'] } + [EVAL['cian_sale_kazan']['url']]) }

      it 'персистит 4 локальных объявления с полями парсинга, отбрасывает Казань' do
        expect(ryazan_finder.call).to eq(4)

        good_urls = good_keys.map { |k| EVAL[k]['url'] }
        expect(ExternalListing.where(url: good_urls).count).to eq(4)
        expect(ExternalListing.where(url: EVAL['cian_sale_kazan']['url'])).not_to exist

        cian = ExternalListing.find_by!(url: EVAL['cian_sale_ryazan']['url'])
        expect(cian.source).to eq('cian')
        expect(cian.price).to eq(4_350_000)
        expect(cian.area).to eq(38.0)
        expect(cian.rooms).to eq(1)
        expect(cian.city).to eq('Рязань')
        expect(cian.district).to eq('Канищево')
        expect(cian.property_type).to eq('flat')
        expect(cian.deal_type).to eq('sale')

        # Полные проверки парсинга для каждой площадки (ревью Kimi, PR #184):
        # price/area/rooms/city, а не только source.
        expected = {
          'avito_sale_ryazan'    => 'avito',
          'yandex_sale_ryazan'   => 'yandex_yrl',
          'domclick_sale_ryazan' => 'cian' # domclick не имеет своего kind — маппится в cian
        }
        expected.each do |key, source|
          el = ExternalListing.find_by!(url: EVAL[key]['url'])
          llm = EVAL[key]['llm_result']
          expect(el.source).to eq(source)
          expect(el.price).to eq(llm['price'])
          expect(el.area).to eq(llm['area'])
          expect(el.rooms).to eq(llm['rooms'])
          expect(el.city).to eq(llm['city'])
          expect(el.deal_type).to eq('sale')
        end
      end
    end

    context 'полный пайплайн: аренда (LLM вернул price=0)' do
      before { stub_eval_tavily([EVAL['avito_rent_ryazan']['url']]) }

      it 'не персистит аренду' do
        expect(ryazan_finder.call).to eq(0)
        expect(ExternalListing.where(url: EVAL['avito_rent_ryazan']['url'])).not_to exist
      end
    end

    context 'дегрейд без ключей / при ошибках' do
      it 'без TAVILY_API_KEY — 0 и ни одного внешнего вызова' do
        allow(ENV).to receive(:[]).with('TAVILY_API_KEY').and_return(nil)

        expect(ryazan_finder.call).to eq(0)
        expect(Tavily::Client).not_to have_received(:new)
        expect(Firecrawl::Client).not_to have_received(:new)
      end

      it 'Tavily::Client::Error не пробрасывается — 0' do
        allow(tavily_client).to receive(:search)
          .and_raise(Tavily::Client::Error, 'quota exceeded')

        expect(ryazan_finder.call).to eq(0)
      end
    end
  end
end
