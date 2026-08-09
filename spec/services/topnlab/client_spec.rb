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

    it 'не утаскивает api-key в текст исключения (он уходит в error_log и в админку)' do
      stub_request(:get, get_ids_re)
        .to_return(status: 200, body: { status: 'error', request: { key: 'test-key' } }.to_json)

      expect { client.get_ids(type: 'realty', action: 'sale', realty_type: 'flat') }
        .to raise_error(Topnlab::Client::Error) { |e|
          expect(e.message).not_to include('test-key')
          expect(e.message).to include('FILTERED')
        }
    end
  end

  describe '#get_entities' do
    let(:get_entities_re) { %r{\Ahttps://crm\.example/get-entities} }

    it 'мержит чанки при 200 + JSON-объекте' do
      stub_request(:get, get_entities_re)
        .to_return(status: 200, body: { '1' => { 'id' => 1 } }.to_json)

      expect(client.get_entities([1])).to eq('1' => { 'id' => 1 })
    end

    it 'возвращает {} без запроса, если ids пуст' do
      expect(client.get_entities([])).to eq({})
      expect(a_request(:get, get_entities_re)).not_to have_been_made
    end

    # Ключевой регресс: раньше не-Hash молча пропускался (`merge! if is_a?(Hash)`),
    # seen_ids оставался неполным при fetch_errors == 0 → archive снимал живые.
    # `{"status":"error"}` — тоже Hash, поэтому проверки is_a?(Hash) мало:
    # он бы смержился, дал ноль id и разблокировал archive при fetch_errors == 0.
    it 'бросает Error на 200 с error-shaped телом (Hash, но не карта сущностей)' do
      stub_request(:get, get_entities_re)
        .to_return(status: 200, body: { status: 'error' }.to_json)

      expect { client.get_entities([1]) }
        .to raise_error(Topnlab::Client::Error, /не карту сущностей/)
    end

    it 'бросает Error на пустой массив — мы запросили конкретные id' do
      stub_request(:get, get_entities_re).to_return(status: 200, body: [].to_json)

      expect { client.get_entities([1]) }
        .to raise_error(Topnlab::Client::Error, /не карту сущностей/)
    end

    it 'бросает Error на пустой Hash — запрошенные id обязаны вернуться' do
      stub_request(:get, get_entities_re).to_return(status: 200, body: {}.to_json)

      expect { client.get_entities([1]) }
        .to raise_error(Topnlab::Client::Error, /не карту сущностей/)
    end
  end
end
