# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Webhooks::NewsIngestController', type: :request do
  describe 'POST /webhooks/news_ingest' do
    let(:token) { 'test-news-ingest-token' }
    let(:headers) { { 'Authorization' => "Bearer #{token}", 'CONTENT_TYPE' => 'application/json' } }
    let(:payload) do
      {
        external_id: 'urgent_20261109_120000',
        title: 'Ипотека рухнула почти вдвое в октябре',
        body_md: 'Объём выдач ипотеки в Рязанской области снизился почти вдвое относительно сентября.',
        category: 'news'
      }
    end

    around do |ex|
      original = ENV['NEWS_INGEST_TOKEN']
      ENV['NEWS_INGEST_TOKEN'] = token
      ex.run
      ENV['NEWS_INGEST_TOKEN'] = original
    end

    it '401 без токена' do
      post '/webhooks/news_ingest', params: payload.to_json,
                                    headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:unauthorized)
    end

    it 'отвечает url с публичным хостом при запросе с внутренним Host-заголовком' do
      # Репро бага #189: chat-host cron дёргает вебхук по адресу docker-сети
      # (web:3000), `_url`-хелпер без явного host: наследовал его из запроса,
      # и в пост TG уходила нерабочая ссылка http://web:3000/news/<slug>.
      post '/webhooks/news_ingest', params: payload.to_json,
                                    headers: headers.merge('HTTP_HOST' => 'web:3000')

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['url']).to start_with('https://victory62.org/news/')
    end

    it 'url ответа не зависит от Host-заголовка (внешний хост в запросе)' do
      post '/webhooks/news_ingest', params: payload.to_json,
                                    headers: headers.merge('HTTP_HOST' => 'example.org')

      expect(response.parsed_body['url']).to start_with('https://victory62.org/news/')
    end

    it 'создаёт статью и отвечает slug созданной записи' do
      post '/webhooks/news_ingest', params: payload.to_json, headers: headers

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body['action']).to eq('created')
      expect(body['slug']).to be_present
      expect(Article.unscoped.where(external_id: 'urgent_20261109_120000').count).to eq(1)
    end

    it 'повторная отправка того же external_id обновляет, а не дублирует' do
      post '/webhooks/news_ingest', params: payload.to_json, headers: headers
      post '/webhooks/news_ingest', params: payload.merge(title: 'Ипотека рухнула почти вдвое в октябре!').to_json,
                                    headers: headers

      expect(response.parsed_body['action']).to eq('updated')
      expect(Article.unscoped.where(external_id: 'urgent_20261109_120000').count).to eq(1)
    end

    it '422 при коротком title' do
      post '/webhooks/news_ingest', params: payload.merge(title: 'коротко').to_json, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']).to eq('invalid_payload')
    end
  end
end
