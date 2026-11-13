# frozen_string_literal: true

require 'rails_helper'

# Тест-режим чат-бота (issue #214): вход через ?visitor_token=<probe-токен>,
# выход — ?visitor_token=off. Произвольный токен из URL игнорируется.
#
# Review round 6 (PR #228): probe-токен принимается только с валидной
# HMAC-подписью (VisitorIdentity.probe_token) — иначе любой мог бы ссылкой
# перевести реального посетителя в тестовый контур на 90 дней куки.
RSpec.describe 'VisitorIdentity', type: :request do
  def open_chat(params = {})
    get chat_conversation_path(format: :json), params: params
    expect(response).to have_http_status(:ok)
  end

  def probe(name) = VisitorIdentity.probe_token(name)

  it 'подписанный probe-токен из URL закрепляется за посетителем и Conversation' do
    open_chat(visitor_token: probe('maria-1211'))

    expect(Conversation.order(:id).last.visitor_token).to eq(probe('maria-1211'))
  end

  it 'самодельный probe-токен без подписи игнорируется (round 6)' do
    open_chat(visitor_token: 'probe-maria-1211')

    expect(Conversation.order(:id).last.visitor_token).not_to start_with('probe-')
  end

  it 'probe-токен с чужой подписью игнорируется (round 6)' do
    forged = probe('maria-1211').sub(/[0-9a-f]{16}\z/, '0' * 16)
    open_chat(visitor_token: forged)

    expect(Conversation.order(:id).last.visitor_token).not_to start_with('probe-')
  end

  it 'имя probe-токена по умолчанию уникально — у прогонов нет общего Conversation' do
    expect(VisitorIdentity.probe_token).not_to eq(VisitorIdentity.probe_token)
  end

  it 'probe-диалог помечается test_probe?, обычный — нет' do
    open_chat
    open_chat(visitor_token: probe('maria-1211'))

    probe_conv = Conversation.find_by!(visitor_token: probe('maria-1211'))
    normal = Conversation.where.not(visitor_token: probe('maria-1211')).order(:id).last
    expect(probe_conv).to be_test_probe
    expect(normal).not_to be_test_probe
  end

  # Issue #227: тумблер «🧪 Тест-прогон» виджета читает флаг из JSON сессии
  # (probe-кука httponly — из JS не прочитать).
  it 'serialize отдаёт test_probe — виджет показывает состояние тумблера' do
    open_chat(visitor_token: probe('widget'))
    expect(response.parsed_body['test_probe']).to be(true)

    open_chat(visitor_token: 'off')
    open_chat
    expect(response.parsed_body['test_probe']).to be(false)
  end

  it 'произвольный visitor_token из URL не принимается' do
    open_chat(visitor_token: 'hacked-token')

    expect(Conversation.order(:id).last.visitor_token).not_to eq('hacked-token')
  end

  it 'слишком длинный probe-токен игнорируется (защита от CookieOverflow)' do
    open_chat(visitor_token: "probe-#{'a' * 100}")

    expect(Conversation.order(:id).last.visitor_token).not_to start_with('probe-')
  end

  it 'probe-токен с длинным именем отклоняется паттерном' do
    open_chat(visitor_token: VisitorIdentity.probe_token('a' * 40))

    expect(Conversation.order(:id).last.visitor_token).not_to start_with('probe-')
  end

  it '?visitor_token=off выводит из тест-режима: следующий визит — обычный токен' do
    open_chat(visitor_token: probe('maria-1211'))
    expect(Conversation.order(:id).last.visitor_token).to eq(probe('maria-1211'))

    open_chat(visitor_token: 'off')

    token = Conversation.order(:id).last.visitor_token
    expect(token).not_to eq(probe('maria-1211'))
    expect(token).not_to start_with('probe-')
  end

  # Rev #230: у каждого браузера/прогона свой серверный probe-токен — общий
  # токен смешивал бы сообщения независимых посетителей в один Conversation.
  it 'два независимых браузера с разными probe-сессиями не смешиваются' do
    session_a = ActionDispatch::Integration::Session.new(Rails.application)
    session_b = ActionDispatch::Integration::Session.new(Rails.application)

    session_a.get chat_conversation_path(format: :json), params: { visitor_token: probe('alice-0001') }
    session_b.get chat_conversation_path(format: :json), params: { visitor_token: probe('bob-0002') }

    expect(session_a.response).to have_http_status(:ok)
    expect(session_b.response).to have_http_status(:ok)
    conv_a = Conversation.find_by!(visitor_token: probe('alice-0001'))
    conv_b = Conversation.find_by!(visitor_token: probe('bob-0002'))
    expect(conv_a.id).not_to eq(conv_b.id)
    expect(conv_a).to be_test_probe
    expect(conv_b).to be_test_probe

    # Повторный визит браузера A — свой Conversation переиспользуется,
    # новых диалогов не создаётся (последним остаётся bob).
    count = Conversation.count
    session_a.get chat_conversation_path(format: :json)
    expect(session_a.response).to have_http_status(:ok)
    expect(Conversation.count).to eq(count)
    expect(Conversation.order(:id).last.visitor_token).to eq(probe('bob-0002'))
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
      open_chat(visitor_token: probe('maria-1211'))

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
