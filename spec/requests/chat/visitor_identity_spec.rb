# frozen_string_literal: true

require 'rails_helper'

# Тест-режим чат-бота (issue #214): вход через ?visitor_token=probe-<имя>,
# выход — ?visitor_token=off. Произвольный токен из URL игнорируется.
RSpec.describe 'VisitorIdentity', type: :request do
  def open_chat(params = {})
    get chat_conversation_path(format: :json), params: params
    expect(response).to have_http_status(:ok)
  end

  it 'probe-токен из URL закрепляется за посетителем и Conversation' do
    open_chat(visitor_token: 'probe-maria-1211')

    expect(Conversation.order(:id).last.visitor_token).to eq('probe-maria-1211')
  end

  it 'probe-диалог помечается test_probe?, обычный — нет' do
    open_chat
    open_chat(visitor_token: 'probe-maria-1211')

    probe = Conversation.find_by!(visitor_token: 'probe-maria-1211')
    normal = Conversation.where.not(visitor_token: 'probe-maria-1211').order(:id).last
    expect(probe).to be_test_probe
    expect(normal).not_to be_test_probe
  end

  it 'произвольный visitor_token из URL не принимается' do
    open_chat(visitor_token: 'hacked-token')

    expect(Conversation.order(:id).last.visitor_token).not_to eq('hacked-token')
  end

  it '?visitor_token=off выводит из тест-режима: следующий визит — обычный токен' do
    open_chat(visitor_token: 'probe-maria-1211')
    expect(Conversation.order(:id).last.visitor_token).to eq('probe-maria-1211')

    open_chat(visitor_token: 'off')

    token = Conversation.order(:id).last.visitor_token
    expect(token).not_to eq('probe-maria-1211')
    expect(token).not_to start_with('probe-')
  end
end
