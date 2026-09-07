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

  it 'ровно MAX_BATCH наблюдений принимается целиком, а не отвергается по границе' do
    post '/webhooks/zhk_ingest',
         params: { observations: Array.new(50) { observation } }.to_json, headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['results'].size).to eq(50)
  end

  it 'пустой список наблюдений — 200 с пустым results, а не 422' do
    post '/webhooks/zhk_ingest', params: { observations: [] }.to_json, headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['results']).to eq([])
  end

  it 'сбой одного наблюдения не откатывает уже применённые соседние (нет общей транзакции на батч)' do
    second_observation = observation.merge('external_id' => 'erz:other-complex')

    call_number = 0
    allow(Zhk::Ingest).to receive(:call).and_wrap_original do |original, payload|
      call_number += 1
      raise 'boom — неожиданный сбой второго наблюдения' if call_number == 2

      original.call(payload)
    end

    # Исключение из второго наблюдения долетает до Rails и рендерится как
    # 500 (не рескьюится этим контроллером — оно НЕ `:invalid`, а
    # программная ошибка, ей и место в пятисотке). Важна не сама пятисотка,
    # а то, что осталось в базе после неё.
    post '/webhooks/zhk_ingest',
         params: { observations: [observation, second_observation] }.to_json, headers: headers

    expect(response).to have_http_status(:internal_server_error)
    # Первое наблюдение успело закоммититься до сбоя второго — если бы
    # `create` оборачивал `observations.map` в общую транзакцию на батч,
    # этот счётчик стал бы 0 (откат утянул бы за собой и первую запись).
    expect(ResidentialComplex.unscoped.count).to eq(1)
  end

  it '503 если ZHK_INGEST_TOKEN не задан — это поломка сервера, а не вина клиента' do
    ENV['ZHK_INGEST_TOKEN'] = nil

    post '/webhooks/zhk_ingest', params: { observations: [observation] }.to_json, headers: headers

    expect(response).to have_http_status(:service_unavailable)
  ensure
    ENV['ZHK_INGEST_TOKEN'] = token
  end

  it '401 если токен прислан без префикса Bearer — голого значения недостаточно' do
    post '/webhooks/zhk_ingest', params: { observations: [observation] }.to_json,
                                 headers: { 'Authorization' => token, 'CONTENT_TYPE' => 'application/json' }

    expect(response).to have_http_status(:unauthorized)
  end
end
