# frozen_string_literal: true

require 'rails_helper'

# Регресс на хардненинг get-ids (prod-инцидент «каталог → 0»).
# Не-массивный 200 (error-shaped body / null) или 404 должны трактоваться как
# ошибка fetch, а НЕ как легитимно пустая выгрузка — иначе Importer#archive_missing
# обнулит весь каталог. Легитимный [] обязан оставаться валидным без raise.
RSpec.describe Topnlab::Client do
  subject(:client) { described_class.new(api_key: 'test-key', base_url: base_url) }

  let(:base_url)  { 'https://crm.example' }
  let(:get_ids_re) { %r{\Ahttps://crm\.example/get-ids} }

  before { WebMock.disable_net_connect! }
  after  { WebMock.allow_net_connect! }

  describe '#get_ids' do
    it 'возвращает массив ids при 200 + JSON-массиве' do
      stub_request(:get, get_ids_re).to_return(status: 200, body: [1, 2, 3].to_json)

      expect(client.get_ids(type: 'realty', action: 'sale', realty_type: 'flat')).to eq([1, 2, 3])
    end

    it 'возвращает [] при легитимно пустой выгрузке и НЕ бросает' do
      stub_request(:get, get_ids_re).to_return(status: 200, body: [].to_json)

      result = nil
      expect { result = client.get_ids(type: 'realty', action: 'sale', realty_type: 'garage') }
        .not_to raise_error
      expect(result).to eq([]) # один вызов: избегаем 6s SLOW_DELAY-throttle между двумя get_ids
    end

    it 'бросает Error на 200 с error-shaped телом (не-массив)' do
      stub_request(:get, get_ids_re).to_return(status: 200, body: { status: 'error' }.to_json)

      expect { client.get_ids(type: 'realty', action: 'sale', realty_type: 'flat') }
        .to raise_error(Topnlab::Client::Error, /не-массив/)
    end

    it 'бросает Error на 200 с телом null' do
      stub_request(:get, get_ids_re).to_return(status: 200, body: 'null')

      expect { client.get_ids(type: 'realty', action: 'sale', realty_type: 'flat') }
        .to raise_error(Topnlab::Client::Error, /не-массив/)
    end

    it 'бросает Error на 404 (parse → nil → не-массив)' do
      stub_request(:get, get_ids_re).to_return(status: 404, body: '')

      expect { client.get_ids(type: 'realty', action: 'sale', realty_type: 'flat') }
        .to raise_error(Topnlab::Client::Error, /не-массив/)
    end
  end
end
