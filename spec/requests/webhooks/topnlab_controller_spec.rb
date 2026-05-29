# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'POST /webhooks/topnlab', type: :request do
  let(:valid_key) { 'test-webhook-secret-key' }

  around do |ex|
    original = ENV['TOPNLAB_WEBHOOK_KEY']
    ENV['TOPNLAB_WEBHOOK_KEY'] = valid_key
    ex.run
    ENV['TOPNLAB_WEBHOOK_KEY'] = original
  end

  describe 'auth (require_topnlab_key)' do
    it '403 при отсутствии key' do
      post '/webhooks/topnlab', params: { id: 123, type: 'realty' }
      expect(response).to have_http_status(:forbidden)
    end

    it '403 при неверном key' do
      post '/webhooks/topnlab', params: { id: 123, type: 'realty', key: 'wrong-key' }
      expect(response).to have_http_status(:forbidden)
    end

    it '503 если TOPNLAB_WEBHOOK_KEY не задан' do
      ENV['TOPNLAB_WEBHOOK_KEY'] = nil
      ENV['TOPNLAB_API_KEY'] = nil
      post '/webhooks/topnlab', params: { id: 123, type: 'realty', key: 'whatever' }
      expect(response).to have_http_status(:service_unavailable)
    ensure
      ENV['TOPNLAB_WEBHOOK_KEY'] = valid_key
    end

    it 'fallback на TOPNLAB_API_KEY если TOPNLAB_WEBHOOK_KEY blank' do
      ENV['TOPNLAB_WEBHOOK_KEY'] = nil
      ENV['TOPNLAB_API_KEY'] = valid_key
      allow(TopnlabPropertyImportJob).to receive(:perform_later)
      # Mock redis nil — skip dedup
      allow_any_instance_of(Webhooks::TopnlabController).to receive(:redis_conn).and_return(nil)

      post '/webhooks/topnlab', params: { id: 456, type: 'realty', key: valid_key }
      expect(response).to have_http_status(:ok)
    ensure
      ENV['TOPNLAB_WEBHOOK_KEY'] = valid_key
      ENV['TOPNLAB_API_KEY'] = nil
    end
  end

  describe 'realty webhook' do
    before do
      allow_any_instance_of(Webhooks::TopnlabController).to receive(:redis_conn).and_return(nil)
    end

    it 'enqueues TopnlabPropertyImportJob' do
      expect(TopnlabPropertyImportJob).to receive(:perform_later).with('789')
      post '/webhooks/topnlab', params: { id: 789, type: 'realty', key: valid_key }
      expect(response).to have_http_status(:ok)
    end

    it 'НЕ enqueues при missing id' do
      expect(TopnlabPropertyImportJob).not_to receive(:perform_later)
      post '/webhooks/topnlab', params: { type: 'realty', key: valid_key }
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'order webhook' do
    before do
      allow_any_instance_of(Webhooks::TopnlabController).to receive(:redis_conn).and_return(nil)
    end

    it 'enqueues TopnlabOrdersSyncJob + TopnlabCrmIntakeJob' do
      expect(TopnlabOrdersSyncJob).to receive(:perform_later)
      expect(TopnlabCrmIntakeJob).to receive(:perform_later).with('555')
      post '/webhooks/topnlab', params: { id: 555, type: 'order', key: valid_key }
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'unknown type' do
    before do
      allow_any_instance_of(Webhooks::TopnlabController).to receive(:redis_conn).and_return(nil)
    end

    it '200 OK без enqueue' do
      expect(TopnlabPropertyImportJob).not_to receive(:perform_later)
      expect(TopnlabOrdersSyncJob).not_to receive(:perform_later)
      post '/webhooks/topnlab', params: { id: 99, type: 'service', key: valid_key }
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'idempotency dedup (Redis SETNX EX 5min)' do
    let(:fake_redis) { instance_double('Redis') }

    before do
      allow_any_instance_of(Webhooks::TopnlabController).to receive(:redis_conn).and_return(fake_redis)
      allow(fake_redis).to receive(:set).with('topnlab:last_webhook_at', anything, anything)
    end

    it '1-й webhook process, 2-й skip (dedup hit)' do
      # 1-я попытка: SETNX returns true (новый key)
      expect(fake_redis).to receive(:set).with('topnlab:webhook:realty:111', '1', nx: true, ex: 300).and_return(true)
      expect(TopnlabPropertyImportJob).to receive(:perform_later).with('111')
      post '/webhooks/topnlab', params: { id: 111, type: 'realty', key: valid_key }
      expect(response).to have_http_status(:ok)

      # 2-я попытка: SETNX returns false (уже есть key) → skip
      expect(fake_redis).to receive(:set).with('topnlab:webhook:realty:111', '1', nx: true, ex: 300).and_return(false)
      expect(TopnlabPropertyImportJob).not_to receive(:perform_later)
      post '/webhooks/topnlab', params: { id: 111, type: 'realty', key: valid_key }
      expect(response).to have_http_status(:ok)
    end

    it 'fail-open при redis exception' do
      allow(fake_redis).to receive(:set).and_raise(StandardError.new('redis down'))
      expect(TopnlabPropertyImportJob).to receive(:perform_later).with('222')
      post '/webhooks/topnlab', params: { id: 222, type: 'realty', key: valid_key }
      expect(response).to have_http_status(:ok)
    end
  end
end
