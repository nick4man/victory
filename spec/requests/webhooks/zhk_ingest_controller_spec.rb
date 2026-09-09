# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Webhooks::ZhkIngestController', type: :request do
  describe 'POST /webhooks/zhk_ingest' do
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

  describe 'POST /webhooks/zhk_ingest/summary' do
    let(:token) { 'test-zhk-ingest-token' }
    let(:headers) { { 'Authorization' => "Bearer #{token}", 'CONTENT_TYPE' => 'application/json' } }
    let(:tg_client) { instance_double(Telegram::Client) }

    around do |ex|
      original_token = ENV['ZHK_INGEST_TOKEN']
      original_chat = ENV['TELEGRAM_STAFF_CHAT_ID']
      ENV['ZHK_INGEST_TOKEN'] = token
      ENV['TELEGRAM_STAFF_CHAT_ID'] = '123456'
      ex.run
      ENV['ZHK_INGEST_TOKEN'] = original_token
      ENV['TELEGRAM_STAFF_CHAT_ID'] = original_chat
    end

    before { allow(Telegram::Client).to receive(:new).and_return(tg_client) }

    it '401 без токена — та же авторизация, что у create' do
      post '/webhooks/zhk_ingest/summary', params: { counts: { 'erz' => 3 } }.to_json,
                                           headers: { 'CONTENT_TYPE' => 'application/json' }

      expect(response).to have_http_status(:unauthorized)
      expect(Telegram::Client).not_to have_received(:new)
    end

    it 'отправляет сводку в staff-чат, отвечает 200 и delivered: true' do
      allow(tg_client).to receive(:send_message)

      post '/webhooks/zhk_ingest/summary', params: { counts: { 'erz' => 3, 'edinstvo' => 7 } }.to_json,
                                           headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq('status' => 'ok', 'delivered' => true)
      expect(tg_client).to have_received(:send_message).with(
        a_string_matching(/erz: 3/), chat_id: '123456'
      )
    end

    it 'вложенный объект в значении counts — 422, а не 500' do
      # `Zhk::RunSummary` везде зовёт `count.to_i`, а у хеша `to_i` нет
      # вовсе — без проверки формы ЗНАЧЕНИЙ это необработанный
      # NoMethodError, то есть 500 на входе, который контроллер обязан
      # отвергать сам (проверка формы контейнера закрывала лишь половину).
      allow(tg_client).to receive(:send_message)

      post '/webhooks/zhk_ingest/summary', params: { counts: { 'erz' => { 'a' => 1 } } }.to_json,
                                           headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']).to eq('invalid_payload')
      expect(response.parsed_body['detail']).to include('erz')
      expect(tg_client).not_to have_received(:send_message)
      expect(ZhkIngestRun.count).to eq(0)
    end

    it 'массив в значении counts — тоже 422' do
      allow(tg_client).to receive(:send_message)

      post '/webhooks/zhk_ingest/summary', params: { counts: { 'erz' => [1, 2] } }.to_json,
                                           headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(ZhkIngestRun.count).to eq(0)
    end

    it 'отрицательный счётчик — тот же JSON-контракт 422, а не HTML-страница исключения' do
      # `ZhkIngestRun` валидирует count >= 0, и `-1` дожил бы до `create!`
      # в `record_run`: `RecordInvalid` наружу — формально тоже 422, но НЕ
      # тем телом, которое обещано во всех остальных отказах. Отрицательное
      # число наблюдений не имеет смысла — отвергаем на входе.
      allow(tg_client).to receive(:send_message)

      post '/webhooks/zhk_ingest/summary', params: { counts: { 'erz' => -1 } }.to_json,
                                           headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']).to eq('invalid_payload')
      expect(response.parsed_body['detail']).to include('erz')
      expect(ZhkIngestRun.count).to eq(0)
    end

    it 'отрицательный счётчик строкой («-1») отвергается так же' do
      # Дыра закрывается на обеих ветках: JSON-целое приходит `Integer` и
      # регэкспа не касается вовсе, строка — наоборот.
      allow(tg_client).to receive(:send_message)

      post '/webhooks/zhk_ingest/summary', params: { counts: { 'erz' => '-1' } }.to_json,
                                           headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']).to eq('invalid_payload')
      expect(ZhkIngestRun.count).to eq(0)
    end

    it 'счётчик строкой («7») принимается — сводка дороже строгости' do
      # Отказ здесь стоит не разобранной сводки, а сводка — единственный
      # носитель тревоги о молчащем источнике.
      allow(tg_client).to receive(:send_message)

      post '/webhooks/zhk_ingest/summary', params: { counts: { 'erz' => '7' } }.to_json,
                                           headers: headers

      expect(response).to have_http_status(:ok)
      expect(ZhkIngestRun.find_by(source: 'erz').count).to eq(7)
    end

    it 'сбой Telegram::Client::Error не превращает уже обработанный прогон в 500, но delivered: false' do
      allow(tg_client).to receive(:send_message).and_raise(Telegram::Client::Error, 'bad request')

      post '/webhooks/zhk_ingest/summary', params: { counts: { 'erz' => 3 } }.to_json, headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['delivered']).to be(false)
    end

    it 'таймаут Net::HTTP (не Telegram::Client::Error) тоже не превращает прогон в 500' do
      # `Telegram::Client#api_call` оборачивает в `Telegram::Client::Error`
      # только ответ вида {"ok": false} — таймаут/DNS-сбой из `Net::HTTP`
      # долетают отсюда НЕ обёрнутыми (круг правок 1, находка ревью).
      allow(tg_client).to receive(:send_message).and_raise(Net::OpenTimeout, 'execution expired')

      post '/webhooks/zhk_ingest/summary', params: { counts: { 'erz' => 3 } }.to_json, headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['delivered']).to be(false)
    end

    it 'без TELEGRAM_STAFF_CHAT_ID сводку не шлёт, отвечает 200 и delivered: false' do
      ENV['TELEGRAM_STAFF_CHAT_ID'] = nil

      post '/webhooks/zhk_ingest/summary', params: { counts: { 'erz' => 3 } }.to_json, headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['delivered']).to be(false)
      expect(Telegram::Client).not_to have_received(:new)
    end

    it '422, а не 500, когда counts не объект' do
      post '/webhooks/zhk_ingest/summary', params: { counts: 5 }.to_json, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(Telegram::Client).not_to have_received(:new)
    end

    it 'записывает прогон в ZhkIngestRun — источник для следующего сравнения' do
      allow(tg_client).to receive(:send_message)

      post '/webhooks/zhk_ingest/summary', params: { counts: { 'erz' => 12 } }.to_json, headers: headers

      run = ZhkIngestRun.for_source('erz').last
      expect(run.count).to eq(12)
    end
  end
end
