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

  # Issue #227: тумблер «🧪 Тест-прогон» виджета читает флаг из JSON сессии
  # (probe-кука httponly — из JS не прочитать).
  it 'serialize отдаёт test_probe — виджет показывает состояние тумблера' do
    open_chat(visitor_token: 'probe-widget', probe_key: probe_secret)
    expect(response.parsed_body['test_probe']).to be(true)

    open_chat(visitor_token: 'off')
    open_chat
    expect(response.parsed_body['test_probe']).to be(false)
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

  # Rev #230 (механизм #229): у каждого браузера/прогона свой случайный
  # серверный токен — общий токен смешивал бы сообщения независимых
  # посетителей в один Conversation.
  it 'два независимых браузера с разными probe-сессиями не смешиваются' do
    session_a = ActionDispatch::Integration::Session.new(Rails.application)
    session_b = ActionDispatch::Integration::Session.new(Rails.application)

    session_a.get chat_conversation_path(format: :json),
                  params: { visitor_token: 'probe-alice-0001', probe_key: probe_secret }
    session_b.get chat_conversation_path(format: :json),
                  params: { visitor_token: 'probe-bob-0002', probe_key: probe_secret }

    expect(session_a.response).to have_http_status(:ok)
    expect(session_b.response).to have_http_status(:ok)
    conv_a, conv_b = Conversation.order(:id).last(2)
    expect(conv_a.id).not_to eq(conv_b.id)
    expect(conv_a).to be_test_probe
    expect(conv_b).to be_test_probe
    expect(conv_a.visitor_token).not_to eq(conv_b.visitor_token)

    # Повторный визит браузера A — свой Conversation переиспользуется,
    # новых диалогов не создаётся (последним остаётся bob).
    count = Conversation.count
    session_a.get chat_conversation_path(format: :json)
    expect(session_a.response).to have_http_status(:ok)
    expect(Conversation.count).to eq(count)
    expect(Conversation.order(:id).last.id).to eq(conv_b.id)
  end

  # Issue #227 (rev #230, round 4): JSON сессии НЕ выдаёт probe_token —
  # публичная выдача HMAC-токена позволила бы переключить чужую сессию в
  # тест-контур на 90 дней. Тумблер идёт через POST /chat/conversation/
  # test_mode (same-origin + CSRF), см. spec/requests/chat/test_mode_toggle_spec.rb.
  it 'serialize НЕ содержит probe_token — публичной выдачи токена нет' do
    open_chat

    expect(response.parsed_body).not_to have_key('probe_token')
  end

  # Issue #227 (rev #230): test_mode в JSON — полный режим диалога (probe ИЛИ
  # auto-test ИЛИ ENV-кран); тумблер читает test_probe, индикатор — test_mode.
  describe 'test_mode в serialize' do
    it 'auto-test сессия: test_mode=true, test_probe=false' do
      host! 'staging.victory62.org'
      open_chat

      expect(response.parsed_body['test_mode']).to be(true)
      expect(response.parsed_body['test_probe']).to be(false)
    end

    it 'probe-сессия: оба флага true' do
      open_chat(visitor_token: 'probe-maria-1211', probe_key: probe_secret)

      expect(response.parsed_body['test_mode']).to be(true)
      expect(response.parsed_body['test_probe']).to be(true)
    end

    it 'боевая сессия с прод-домена: оба флага false' do
      host! 'victory62.org'
      open_chat

      expect(response.parsed_body['test_mode']).to be(false)
      expect(response.parsed_body['test_probe']).to be(false)
    end
  end
end
