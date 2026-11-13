# frozen_string_literal: true

require 'rails_helper'

# Issue #227 (rev #230, round 4): тумблер «🧪 Тест-прогон» переключает режим
# через POST /chat/conversation/test_mode. Блокер ревью: публичная выдача
# HMAC probe-токена в JSON сессии позволяла любому анониму переключить чужую
# сессию в тест-контур на 90 дней (ссылка ?visitor_token=<token>) и разделить
# с жертвой один Conversation. Поэтому:
#   - токен мятит ТОЛЬКО сервер, из URL/JSON токен не принимается;
#   - endpoint same-origin с CSRF (в test-окружении защита выключена
#     глобально — включаем allow_forgery_protection на время этих примеров).
RSpec.describe 'Chat::Тумблер тест-прогона (POST /chat/conversation/test_mode)', type: :request do
  def toggle(enabled)
    post '/chat/conversation/test_mode',
         params: { enabled: enabled }.to_json,
         headers: { 'CONTENT_TYPE' => 'application/json', 'HOST' => 'victory62.org' }
  end

  def open_chat
    get '/chat/conversation', params: { format: :json }, headers: { 'HOST' => 'victory62.org' }
    expect(response).to have_http_status(:ok)
  end

  # Свежая запись: let мемоизируется, а действие создаёт НОВЫЙ Conversation.
  def last_conversation
    Conversation.order(:id).last
  end

  describe 'включение тест-режима' do
    it 'сервер мятит свежий HMAC probe-токен — новый диалог test_probe' do
      open_chat
      token_before = last_conversation.visitor_token

      toggle(true)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['test_probe']).to be(true)
      expect(response.parsed_body['test_mode']).to be(true)

      # Новый Conversation под свежим probe-токеном — старый диалог не тронут.
      expect(last_conversation.visitor_token).not_to eq(token_before)
      expect(last_conversation.visitor_token).to match(VisitorIdentity::PROBE_TOKEN_PATTERN)
      expect(VisitorIdentity.valid_probe_token?(last_conversation.visitor_token)).to be(true)
      expect(last_conversation).to be_test_probe

      # Повторный show — состояние держится по куке.
      open_chat
      expect(response.parsed_body['test_probe']).to be(true)
    end

    it 'серверный токен уникален на включение — два прогона не делят Conversation' do
      toggle(true)
      first = last_conversation.visitor_token

      toggle(false)
      toggle(true)

      expect(last_conversation.visitor_token).not_to eq(first)
    end
  end

  describe 'выключение' do
    it 'свежий случайный токен — новый пустой боевой диалог, test_probe false' do
      toggle(true)
      expect(last_conversation).to be_test_probe

      toggle(false)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['test_probe']).to be(false)
      expect(response.parsed_body['test_mode']).to be(false)
      expect(last_conversation.visitor_token).not_to match(VisitorIdentity::PROBE_TOKEN_PATTERN)

      open_chat
      expect(response.parsed_body['test_probe']).to be(false)
    end
  end

  describe 'CSRF-защита (same-origin)' do
    around do |example|
      ActionController::Base.allow_forgery_protection = true
      example.run
    ensure
      ActionController::Base.allow_forgery_protection = false
    end

    it 'POST без X-CSRF-Token отклонён — чужой сайт не переключит сессию' do
      open_chat
      toggle(true)

      # InvalidAuthenticityToken → 422 (show_exceptions обрабатывает в request-spec).
      expect(response).to have_http_status(:unprocessable_entity)

      # Диалог остался боевым — переключения не произошло.
      expect(last_conversation).not_to be_test_probe
    end

    # Как в боевом виджете: csrf_meta_tags в layout отдаёт токен страницы,
    # JS шлёт его в X-CSRF-Token.
    it 'POST с валидным X-CSRF-Token (из meta страницы) проходит' do
      get '/', headers: { 'HOST' => 'victory62.org' }
      expect(response).to have_http_status(:ok)
      csrf = response.body[/<meta name="csrf-token" content="([^"]+)"/, 1]
      expect(csrf).to be_present

      open_chat
      post '/chat/conversation/test_mode',
           params: { enabled: true }.to_json,
           headers: { 'CONTENT_TYPE' => 'application/json', 'HOST' => 'victory62.org',
                      'HTTP_X_CSRF_TOKEN' => csrf }

      expect(response).to have_http_status(:ok)
      expect(last_conversation).to be_test_probe
    end
  end
end
