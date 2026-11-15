# frozen_string_literal: true

require 'rails_helper'

# Тест-режим чат-бота (issue #214, защита #229): вход через
# ?visitor_token=probe-<имя>&probe_key=<секрет>. Без секрета предсказуемый
# URL ничего не меняет — иначе любая присланная ссылка молча переводит
# посетителя в тестовый контур (блокер ревью PR #228). Имя прогона — метка
# для человека; в cookie и Conversation уходит случайный токен, маркер
# прогона живёт в metadata разговора. Выход — ?visitor_token=off.
RSpec.describe 'VisitorIdentity', type: :request do
  let(:probe_secret) { 'test-probe-secret-123' }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('CHAT_PROBE_SECRET').and_return(probe_secret)
    allow(ENV).to receive(:[]).with('ADMIN_TOKEN').and_return(nil)
  end

  def open_chat(params = {})
    get chat_conversation_path(format: :json), params: params
    expect(response).to have_http_status(:ok)
    Conversation.order(:id).last
  end

  it 'probe URL без секрета не переводит посетителя в тестовый контур' do
    conv = open_chat(visitor_token: 'probe-maria-1211')

    expect(conv.test_probe?).to be(false)
    expect(conv.visitor_token).not_to eq('probe-maria-1211')
    expect(conv.visitor_token).to match(/\A[0-9a-f]{32}\z/)
  end

  it 'probe URL с неверным секретом не активирует режим' do
    conv = open_chat(visitor_token: 'probe-maria-1211', probe_key: 'wrong-secret')

    expect(conv.test_probe?).to be(false)
    expect(conv.visitor_token).to match(/\A[0-9a-f]{32}\z/)
  end

  it 'probe URL с верным секретом активирует тестовый контур' do
    conv = open_chat(visitor_token: 'probe-maria-1211', probe_key: probe_secret)

    expect(conv.test_probe?).to be(true)
    expect(conv.visitor_token).not_to start_with('probe-')
  end

  it 'два прогона с одинаковым именем дают разные токены и Conversation' do
    first = open_chat(visitor_token: 'probe-maria-1211', probe_key: probe_secret)
    open_chat(visitor_token: 'off')
    second = open_chat(visitor_token: 'probe-maria-1211', probe_key: probe_secret)

    expect(first.test_probe?).to be(true)
    expect(second.test_probe?).to be(true)
    expect(second.visitor_token).not_to eq(first.visitor_token)
  end

  it 'повторная активация с тем же именем перевыпускает токен прогона' do
    first = open_chat(visitor_token: 'probe-maria-1211', probe_key: probe_secret)
    second = open_chat(visitor_token: 'probe-maria-1211', probe_key: probe_secret)

    expect(second.visitor_token).not_to eq(first.visitor_token)
  end

  it 'произвольный visitor_token из URL не принимается' do
    conv = open_chat(visitor_token: 'hacked-token')

    expect(conv.visitor_token).not_to eq('hacked-token')
  end

  it 'слишком длинный probe-токен игнорируется даже с верным секретом (защита от CookieOverflow)' do
    conv = open_chat(visitor_token: "probe-#{'a' * 100}", probe_key: probe_secret)

    expect(conv.test_probe?).to be(false)
    expect(conv.visitor_token).not_to start_with('probe-')
  end

  it 'probe-режим недоступен, если секрет не настроен на сервере' do
    allow(ENV).to receive(:[]).with('CHAT_PROBE_SECRET').and_return(nil)

    conv = open_chat(visitor_token: 'probe-maria-1211', probe_key: probe_secret)

    expect(conv.test_probe?).to be(false)
  end

  it '?visitor_token=off выводит из тест-режима: следующий визит — боевой токен' do
    probe = open_chat(visitor_token: 'probe-maria-1211', probe_key: probe_secret)
    expect(probe.test_probe?).to be(true)

    off = open_chat(visitor_token: 'off')
    expect(off.visitor_token).not_to eq(probe.visitor_token)

    normal = open_chat
    expect(normal.test_probe?).to be(false)
    expect(normal.visitor_token).to match(/\A[0-9a-f]{32}\z/)
  end

  it 'боевой визитор без параметров получает обычный SecureRandom-токен' do
    conv = open_chat

    expect(conv.test_probe?).to be(false)
    expect(conv.visitor_token).to match(/\A[0-9a-f]{32}\z/)
  end
end
