# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::OmniClient do
  let(:omni) { 'http://omni.test/v1' }
  let(:ok_body) do
    { choices: [{ message: { role: 'assistant', content: 'Привет' } }] }.to_json
  end

  around do |ex|
    keep = ENV.to_h.select { |k, _| k.start_with?('LLM_CHAIN_') || k.start_with?('KIMI_') }
    ENV.keys.grep(/\ALLM_CHAIN_/).each { |k| ENV.delete(k) }
    ENV['KIMI_API_KEY'] = 'kimi-secret'
    ENV.delete('KIMI_BASE_URL')
    ex.run
  ensure
    ENV.keys.grep(/\A(LLM_CHAIN_|KIMI_)/).each { |k| ENV.delete(k) }
    keep.each { |k, v| ENV[k] = v }
  end

  def client = described_class.new(base_url: omni, api_key: 'omni-secret')

  it 'модель kimi/<id> уходит напрямую в Kimi API: свой ключ, temperature=1, User-Agent' do
    ENV['LLM_CHAIN_CHAT'] = 'kimi/kimi-for-coding-highspeed'
    stub = stub_request(:post, 'https://api.kimi.ai/coding/v1/chat/completions')
           .with(headers: { 'Authorization' => 'Bearer kimi-secret', 'User-Agent' => /victory62/ }) do |req|
             b = JSON.parse(req.body)
             b['model'] == 'kimi-for-coding-highspeed' && b['temperature'] == 1
           end
           .to_return(status: 200, body: ok_body)

    res = client.complete([{ role: 'user', content: 'hi' }], temperature: 0.6)

    expect(stub).to have_been_requested
    expect(res[:content]).to eq('Привет')
    expect(res[:model]).to eq('kimi/kimi-for-coding-highspeed')
  end

  it 'KIMI_BASE_URL переопределяет регион' do
    ENV['LLM_CHAIN_CHAT'] = 'kimi/k3'
    ENV['KIMI_BASE_URL']  = 'https://api.kimi.com/coding/v1/'
    stub = stub_request(:post, 'https://api.kimi.com/coding/v1/chat/completions').to_return(status: 200, body: ok_body)

    client.complete([{ role: 'user', content: 'hi' }])

    expect(stub).to have_been_requested
  end

  it 'остальные модели по-прежнему идут через OmniRoute без подмены temperature' do
    ENV['LLM_CHAIN_CHAT'] = 'gemini/gemini-2.5-flash'
    stub = stub_request(:post, "#{omni}/chat/completions")
           .with(headers: { 'Authorization' => 'Bearer omni-secret' }) do |req|
             b = JSON.parse(req.body)
             b['model'] == 'gemini/gemini-2.5-flash' && b['temperature'] == 0.6
           end
           .to_return(status: 200, body: ok_body)

    client.complete([{ role: 'user', content: 'hi' }], temperature: 0.6)

    expect(stub).to have_been_requested
  end

  it 'сбой Kimi → следующая модель цепочки через OmniRoute' do
    ENV['LLM_CHAIN_CHAT'] = 'kimi/k3,gemini/gemini-2.5-flash'
    stub_request(:post, 'https://api.kimi.ai/coding/v1/chat/completions').to_return(status: 429, body: '{}')
    omni_stub = stub_request(:post, "#{omni}/chat/completions").to_return(status: 200, body: ok_body)

    res = client.complete([{ role: 'user', content: 'hi' }])

    expect(omni_stub).to have_been_requested
    expect(res[:attempts]).to eq(2)
  end

  it 'нет KIMI_API_KEY → модель пропускается, цепочка идёт дальше' do
    ENV.delete('KIMI_API_KEY')
    ENV['LLM_CHAIN_CHAT'] = 'kimi/k3,gemini/gemini-2.5-flash'
    omni_stub = stub_request(:post, "#{omni}/chat/completions").to_return(status: 200, body: ok_body)

    client.complete([{ role: 'user', content: 'hi' }])

    expect(omni_stub).to have_been_requested
  end

  describe 'конфиг OmniRoute в initialize' do
    it 'без OmniRoute и с цепочками только из kimi/ — клиент создаётся' do
      ENV['LLM_CHAIN_CHAT'] = 'kimi/k3'
      expect { described_class.new(base_url: nil, api_key: nil) }.not_to raise_error
    end

    it 'без OmniRoute и с OmniRoute-моделью в цепочке — fail-fast, как раньше' do
      ENV['LLM_CHAIN_CHAT'] = 'kimi/k3,gemini/gemini-2.5-flash'
      expect { described_class.new(base_url: nil, api_key: nil) }.to raise_error(described_class::Error, /OMNIROUTE_BASE_URL/)
    end

    it 'без OmniRoute и с пустыми цепочками — fail-fast' do
      ENV['LLM_CHAIN_CHAT'] = ' , '
      expect { described_class.new(base_url: nil, api_key: nil) }.to raise_error(described_class::Error)
    end
  end
end
