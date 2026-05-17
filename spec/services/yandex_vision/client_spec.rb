# frozen_string_literal: true

require 'rails_helper'

RSpec.describe YandexVision::Client do
  let(:api_key)   { 'test_api_key' }
  let(:folder_id) { 'test_folder' }
  let(:client)    { described_class.new(api_key: api_key, folder_id: folder_id) }

  describe '#text_detection' do
    let(:image_url) { 'https://example.com/passport.jpg' }

    let(:successful_response) do
      {
        'results' => [
          {
            'results' => [
              {
                'textAnnotation' => {
                  'pages' => [
                    {
                      'blocks' => [
                        {
                          'lines' => [
                            { 'words' => [{ 'text' => 'РОССИЙСКАЯ' }, { 'text' => 'ФЕДЕРАЦИЯ' }] },
                            { 'words' => [{ 'text' => 'ПАСПОРТ' }] }
                          ]
                        }
                      ]
                    }
                  ]
                }
              }
            ]
          }
        ]
      }
    end

    before do
      # Stub Rails.cache to return nil (не кэшировано)
      allow(Rails.cache).to receive(:read).and_return(nil)
      allow(Rails.cache).to receive(:write)
    end

    context 'when API returns success' do
      before do
        stub_request(:post, 'https://vision.api.cloud.yandex.net/vision/v1/batchAnalyze')
          .to_return(
            status: 200,
            body: successful_response.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )
      end

      it 'returns hash with text and blocks' do
        result = client.text_detection(image_url)
        expect(result).to include('text', 'blocks')
      end

      it 'joins words into text string' do
        result = client.text_detection(image_url)
        expect(result['text']).to include('РОССИЙСКАЯ')
        expect(result['text']).to include('ПАСПОРТ')
      end

      it 'writes to cache' do
        client.text_detection(image_url)
        expect(Rails.cache).to have_received(:write).once
      end
    end

    context 'when API returns HTTP 429 (rate limit)' do
      before do
        stub_request(:post, 'https://vision.api.cloud.yandex.net/vision/v1/batchAnalyze')
          .to_return(status: 429, body: '{"error": "rate limit exceeded"}')
        allow(client).to receive(:sleep)  # не ждём реально
      end

      it 'soft-fails and returns nil (does not raise)' do
        expect(client.text_detection(image_url)).to be_nil
      end
    end

    context 'when network is unreachable' do
      before do
        stub_request(:post, 'https://vision.api.cloud.yandex.net/vision/v1/batchAnalyze')
          .to_raise(Net::OpenTimeout)
        allow(client).to receive(:sleep)
      end

      it 'soft-fails and returns nil' do
        expect(client.text_detection(image_url)).to be_nil
      end
    end

    context 'when result is cached' do
      let(:cached_result) { { 'text' => 'CACHED TEXT', 'blocks' => [] } }

      before do
        allow(Rails.cache).to receive(:read).and_return(cached_result)
      end

      it 'returns cached result without HTTP call' do
        result = client.text_detection(image_url)
        expect(result).to eq(cached_result)
        # No HTTP request should have been made
      end
    end
  end

  describe '#classify' do
    let(:image_url) { 'https://example.com/doc.jpg' }

    let(:classify_response) do
      {
        'results' => [
          {
            'results' => [
              {
                'classificationResult' => {
                  'properties' => [
                    { 'name' => 'document', 'probability' => 0.94 },
                    { 'name' => 'face',     'probability' => 0.71 }
                  ]
                }
              }
            ]
          }
        ]
      }
    end

    before do
      allow(Rails.cache).to receive(:read).and_return(nil)
      allow(Rails.cache).to receive(:write)
      stub_request(:post, 'https://vision.api.cloud.yandex.net/vision/v1/batchAnalyze')
        .to_return(status: 200, body: classify_response.to_json,
                   headers: { 'Content-Type' => 'application/json' })
    end

    it 'returns label confidence hash' do
      result = client.classify(image_url)
      expect(result).to eq('document' => 0.94, 'face' => 0.71)
    end
  end

  describe 'auth header' do
    it 'sends Authorization: Api-Key header' do
      allow(Rails.cache).to receive(:read).and_return(nil)
      allow(Rails.cache).to receive(:write)

      stub = stub_request(:post, 'https://vision.api.cloud.yandex.net/vision/v1/batchAnalyze')
        .with(headers: { 'Authorization' => "Api-Key #{api_key}" })
        .to_return(status: 200, body: { 'results' => [] }.to_json,
                   headers: { 'Content-Type' => 'application/json' })

      client.text_detection('https://example.com/img.jpg')
      expect(stub).to have_been_requested
    end
  end
end
