# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'POST /webhooks/zhk_ingest', type: :request do
  let(:token) { 'test-zhk-ingest-token' }
  let(:observation) { JSON.parse(Rails.root.join('spec/fixtures/zhk/observation_example.json').read) }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'CONTENT_TYPE' => 'application/json' } }

  around do |ex|
    original = ENV['ZHK_INGEST_TOKEN']
    ENV['ZHK_INGEST_TOKEN'] = token
    ex.run
    ENV['ZHK_INGEST_TOKEN'] = original
  end

  it '401 без токена' do
    post '/webhooks/zhk_ingest', params: { observations: [observation] }.to_json,
                                 headers: { 'CONTENT_TYPE' => 'application/json' }

    expect(response).to have_http_status(:unauthorized)
  end

  it 'принимает батч и отвечает построчным отчётом' do
    post '/webhooks/zhk_ingest', params: { observations: [observation] }.to_json, headers: headers

    expect(response).to have_http_status(:ok)
    row = response.parsed_body['results'].first
    expect(row['status']).to eq('created')
    expect(row['external_id']).to eq('erz:564336001')
  end

  it 'повторная отправка того же батча ничего не создаёт' do
    post '/webhooks/zhk_ingest', params: { observations: [observation] }.to_json, headers: headers
    post '/webhooks/zhk_ingest', params: { observations: [observation] }.to_json, headers: headers

    expect(response.parsed_body['results'].first['status']).to eq('duplicate')
    expect(ResidentialComplex.unscoped.count).to eq(1)
  end

  it 'отбивает батч длиннее лимита — служба обязана резать сама' do
    post '/webhooks/zhk_ingest',
         params: { observations: Array.new(51) { observation } }.to_json, headers: headers

    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'плохое наблюдение не роняет остальные' do
    post '/webhooks/zhk_ingest',
         params: { observations: [observation.except('name'), observation] }.to_json, headers: headers

    statuses = response.parsed_body['results'].map { |r| r['status'] }
    expect(statuses).to eq(%w[invalid created])
  end
end
