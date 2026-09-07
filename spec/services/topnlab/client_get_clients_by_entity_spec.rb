# frozen_string_literal: true

require 'rails_helper'

# Пустой список и сбой интеграции обязаны различаться: три месяца оба выглядели
# одинаково (skipped в сводке джоба), и то, что связей продавца с объектом в
# Topnlab нет вовсе, обнаружилось только ручной проверкой.
#
# HTTP подменяется через WebMock, а не заглушкой метода на самом клиенте: стаб
# на объекте под тестом проверял бы собственную заглушку, а не разбор ответа —
# ровно то, что ловит RSpec/SubjectStub.
RSpec.describe Topnlab::Client, '#get_clients_by_entity' do
  subject(:client) { described_class.new(api_key: 'test-key', base_url: base_url) }

  let(:base_url) { 'https://crm.example' }
  let(:endpoint) { %r{\Ahttps://crm\.example/clients/get-by-entity} }

  before { WebMock.disable_net_connect! }
  after  { WebMock.allow_net_connect! }

  it 'возвращает клиентов, когда они есть' do
    stub_request(:post, endpoint).to_return(
      status: 200,
      body: { status: 'success', data: { clients: [{ id: 1, firstname: 'Иван' }] } }.to_json
    )

    expect(client.get_clients_by_entity(entity_id: 42).size).to eq(1)
  end

  it 'возвращает пустой список, когда клиентов действительно нет' do
    stub_request(:post, endpoint).to_return(
      status: 200,
      body: { status: 'success', data: { clients: [], client_legals: [] } }.to_json
    )

    expect(client.get_clients_by_entity(entity_id: 42)).to eq([])
  end

  it 'не путает отсутствие данных с ошибкой' do
    stub_request(:post, endpoint).to_return(
      status: 200, body: { status: 'error', message: 'invalid key' }.to_json
    )

    expect { client.get_clients_by_entity(entity_id: 42) }
      .to raise_error(Topnlab::Client::Error, /неуспешный ответ/)
  end

  it 'поднимает ошибку, когда ответ вообще не похож на ожидаемый' do
    stub_request(:post, endpoint).to_return(status: 502, body: '<html>502</html>')

    expect { client.get_clients_by_entity(entity_id: 42) }
      .to raise_error(Topnlab::Client::Error)
  end
end
