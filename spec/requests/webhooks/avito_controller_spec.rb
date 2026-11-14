# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Webhooks::AvitoController, type: :request do
  let(:webhook_secret) { 'super-secret-token' }
  let(:payload) do
    {
      payload: {
        type: 'message',
        value: {
          id: 'msg_123',
          chat_id: 'chat_456',
          chat_type: 'u2i',
          author_id: 987_654,
          user_id: 123_456,
          item_id: 111_222_333,
          type: 'text',
          created: 1_700_000_000,
          content: { text: 'Можно посмотреть?' }
        }
      }
    }
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('AVITO_WEBHOOK_SECRET').and_return(webhook_secret)
    allow(Avito::InboundProcessorJob).to receive(:perform_async)
  end

  describe 'POST /webhooks/avito' do
    it 'принимает валидный webhook и ставит задачу в очередь' do
      post webhooks_avito_path(token: webhook_secret), params: payload.to_json, headers: json_headers

      expect(response).to have_http_status(:ok)
      expect(Avito::InboundProcessorJob).to have_received(:perform_async).with(a_kind_of(Hash))
    end

    it 'отклоняет запрос с неверным токеном' do
      post webhooks_avito_path(token: 'wrong'), params: payload.to_json, headers: json_headers

      expect(response).to have_http_status(:unauthorized)
      expect(Avito::InboundProcessorJob).not_to have_received(:perform_async)
    end

    it 'возвращает 200 даже при пустом теле' do
      post webhooks_avito_path(token: webhook_secret), params: '', headers: json_headers

      expect(response).to have_http_status(:ok)
      expect(Avito::InboundProcessorJob).not_to have_received(:perform_async)
    end

    context 'когда секрет не настроен' do
      let(:webhook_secret) { '' }

      it 'отказывает с 501 Not Implemented и не ставит задачу в очередь' do
        post webhooks_avito_path, params: payload.to_json, headers: json_headers

        expect(response).to have_http_status(:not_implemented)
        expect(Avito::InboundProcessorJob).not_to have_received(:perform_async)
      end
    end
  end

  def json_headers
    { 'CONTENT_TYPE' => 'application/json' }
  end
end
