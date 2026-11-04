# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::Client do
  subject(:client) { described_class.new(token: 'test-token') }

  let(:ok_response) do
    instance_double(Net::HTTPOK, body: '{"ok":true,"result":{"id":1}}', code: '200')
  end

  describe 'network error handling (with_network_retry)' do
    it 'ретраит транзиентную сетевую ошибку и завершается успехом' do
      attempts = 0
      allow(Net::HTTP).to receive(:start) do |*_args, **_kwargs, &block|
        attempts += 1
        raise Net::OpenTimeout if attempts < 3

        block.call(instance_double(Net::HTTP, request: ok_response))
      end

      expect(client.get_me).to eq('id' => 1)
      expect(attempts).to eq(3)
    end

    it 'оборачивает устойчивую сетевую ошибку в Telegram::Client::Error после ретраев' do
      allow(Net::HTTP).to receive(:start)
        .and_raise(OpenSSL::SSL::SSLError, 'SSL_connect unexpected eof while reading')

      expect { client.get_me }
        .to raise_error(Telegram::Client::Error, /network error after 3 attempts.*SSLError/)
    end
  end
end
