# frozen_string_literal: true

require 'rails_helper'

# Пустой список и сбой интеграции обязаны различаться: три месяца оба выглядели
# одинаково (skipped в сводке джоба), и то, что связей продавца с объектом в
# Topnlab нет вовсе, обнаружилось только ручной проверкой.
RSpec.describe Topnlab::Client, '#get_clients_by_entity' do
  subject(:client) { described_class.new }

  def stub_response(payload)
    allow(client).to receive(:http_post_json).and_return(payload)
  end

  it 'возвращает клиентов, когда они есть' do
    stub_response('status' => 'success',
                  'data' => { 'clients' => [{ 'id' => 1, 'firstname' => 'Иван' }] })

    expect(client.get_clients_by_entity(entity_id: 42).size).to eq(1)
  end

  it 'возвращает пустой список, когда клиентов действительно нет' do
    stub_response('status' => 'success', 'data' => { 'clients' => [], 'client_legals' => [] })

    expect(client.get_clients_by_entity(entity_id: 42)).to eq([])
  end

  it 'не путает отсутствие данных с ошибкой' do
    stub_response('status' => 'error', 'message' => 'invalid key')

    expect { client.get_clients_by_entity(entity_id: 42) }
      .to raise_error(Topnlab::Client::Error, /неуспешный ответ/)
  end

  it 'поднимает ошибку, когда ответ вообще не похож на ожидаемый' do
    stub_response('<html>502</html>')

    expect { client.get_clients_by_entity(entity_id: 42) }
      .to raise_error(Topnlab::Client::Error)
  end
end
