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
end
