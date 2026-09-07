# frozen_string_literal: true

require 'rails_helper'

# A2 Фаза 3 — публичная страница ЖК `/zhk/:slug`.
#
# Основной риск здесь — soft-404: контроллер обязан отдавать настоящий
# HTTP 404 на неизвестный slug (не редирект дефолтного `record_not_found`,
# не 200 с «не найдено» внутри), а noindex-guard обязан отличать «страницы
# нет» (404) от «страница есть, но временно без инвентаря» (200 + noindex).
RSpec.describe 'ResidentialComplexes (публичная страница ЖК)', type: :request do
  describe 'GET /zhk/:slug — неизвестный slug' do
    it 'отдаёт настоящий 404, не редирект и не soft-200' do
      get '/zhk/nesushchestvuyushchiy'

      expect(response).to have_http_status(:not_found)
      expect(response.body).to include('СТРАНИЦА НЕ НАЙДЕНА')
    end
  end

  describe 'GET /zhk/:slug — неопубликованный ЖК' do
    it 'отдаёт 404 (черновик не должен быть публично доступен)' do
      draft = create(:residential_complex, :with_body, published: false)

      get "/zhk/#{draft.slug}"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'GET /zhk/:slug — опубликованный ЖК с текстом и объектами' do
    let!(:complex) { create(:residential_complex, :with_body, name: 'Легенда') }

    before { create_list(:property, 2, :on_site, residential_complex: complex) }

    it 'отдаёт 200 с одним H1 и без noindex' do
      get "/zhk/#{complex.slug}"

      expect(response).to have_http_status(:ok)
      doc = response.parsed_body
      expect(doc.css('h1').size).to eq(1)
      expect(doc.css('h1').text).to include('Легенда')
      expect(doc.at_css('meta[name="robots"][content*="noindex"]')).to be_nil
    end

    it 'canonical без query-string' do
      get "/zhk/#{complex.slug}?utm_source=test"

      doc = response.parsed_body
      canonical = doc.at_css('link[rel="canonical"]')['href']
      expect(canonical).not_to include('utm_source')
      expect(canonical).to end_with("/zhk/#{complex.slug}")
    end

    it 'выставляет публичный Cache-Control' do
      get "/zhk/#{complex.slug}"

      expect(response.headers['Cache-Control']).to include('max-age=900', 'public')
    end

    it 'содержит ApartmentComplex и BreadcrumbList в @graph' do
      get "/zhk/#{complex.slug}"

      graph_script = response.parsed_body.css('script[type="application/ld+json"]').map(&:text)
                             .map { |t| JSON.parse(t) }
                             .find { |json| json['@graph'].present? }
      types = graph_script['@graph'].map { |node| node['@type'] }
      expect(types).to include('ApartmentComplex', 'BreadcrumbList', 'CollectionPage')
    end

    it 'ровно один fetchpriority="high" в разметке (грид без hero-фото)' do
      get "/zhk/#{complex.slug}"

      expect(response.body.scan('fetchpriority="high"').size).to eq(1)
    end
  end

  describe 'GET /zhk/:slug — опубликованный ЖК без текста и без объектов' do
    it 'noindex,follow присутствует и статус остаётся 200 (не soft-404 в смысле шаблона ошибки)' do
      empty_complex = create(:residential_complex, published: true, body_blocks: [])

      get "/zhk/#{empty_complex.slug}"

      expect(response).to have_http_status(:ok)
      doc = response.parsed_body
      expect(doc.at_css('meta[name="robots"]')['content']).to eq('noindex,follow')
    end
  end

  describe 'GET /zhk/:slug — опубликованный ЖК без текста, но с объектами' do
    it 'indexable? => объекты есть => без noindex' do
      complex = create(:residential_complex, published: true, body_blocks: [])
      create(:property, :on_site, residential_complex: complex)

      get "/zhk/#{complex.slug}"

      doc = response.parsed_body
      expect(doc.at_css('meta[name="robots"][content*="noindex"]')).to be_nil
    end
  end

  describe 'GET /zhk/:slug — исторический слаг' do
    it 'резолвится через friendly_id history и 301-редиректит на канонический' do
      complex = create(:residential_complex, :with_body)
      old_slug = complex.slug
      complex.update!(slug: 'novoe-imya')

      get "/zhk/#{old_slug}"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.headers['Location']).to end_with('/zhk/novoe-imya')
    end
  end
end
