# frozen_string_literal: true

require 'rails_helper'

# Issue #227 (п.4): auto-test по происхождению — сессии с не-прод хоста
# (staging, localhost) или с IP из офисного пула автоматически тестовые.
# Флаг metadata['auto_test'] ставят Chat-контроллеры и не снимают обратно.
RSpec.describe 'Chat::AutoTest по происхождению', type: :request do
  around do |example|
    old_ips  = ENV.fetch('SITE_CHATBOT_OFFICE_IPS', nil)
    old_prod = ENV.fetch('SITE_CHATBOT_PROD_HOSTS', nil)
    old_force = ENV.fetch('SITE_CHATBOT_FORCE_TEST', nil)
    ENV.delete('SITE_CHATBOT_OFFICE_IPS')
    ENV.delete('SITE_CHATBOT_PROD_HOSTS')
    ENV.delete('SITE_CHATBOT_FORCE_TEST')
    example.run
    old_ips.nil? ? ENV.delete('SITE_CHATBOT_OFFICE_IPS') : ENV['SITE_CHATBOT_OFFICE_IPS'] = old_ips
    old_prod.nil? ? ENV.delete('SITE_CHATBOT_PROD_HOSTS') : ENV['SITE_CHATBOT_PROD_HOSTS'] = old_prod
    old_force.nil? ? ENV.delete('SITE_CHATBOT_FORCE_TEST') : ENV['SITE_CHATBOT_FORCE_TEST'] = old_force
  end

  def open_chat(host: 'victory62.org')
    get chat_conversation_path(format: :json), headers: { 'HOST' => host }
    expect(response).to have_http_status(:ok)
  end

  let(:conversation) { Conversation.order(:id).last }

  it 'staging-хост на bootstrap → auto_test, lead_test_mode?' do
    open_chat(host: 'staging.victory62.org')

    expect(conversation.reload.metadata['auto_test']).to be(true)
    expect(conversation).to be_lead_test_mode
  end

  it 'localhost на bootstrap → auto_test' do
    open_chat(host: 'localhost')

    expect(conversation.reload.metadata['auto_test']).to be(true)
  end

  it 'прод-домен → без auto_test, lead_test_mode? false (регрессия боевого пути)' do
    open_chat(host: 'victory62.org')

    expect(conversation.reload.metadata['auto_test']).not_to be(true)
    expect(conversation).not_to be_lead_test_mode
  end

  it 'прод-домен, но офисный IP → auto_test (IP перевешивает хост)' do
    ENV['SITE_CHATBOT_OFFICE_IPS'] = '192.168.1.'
    get chat_conversation_path(format: :json),
        headers: { 'HOST' => 'victory62.org', 'REMOTE_ADDR' => '192.168.1.77' }
    expect(response).to have_http_status(:ok)

    expect(conversation.reload.metadata['auto_test']).to be(true)
  end

  # Rev #230: запрос на боевой endpoint, но Origin/Referer со staging/localhost
  # (виджет стучится напрямую) → auto_test; внешний Referer боевого клиента
  # (поисковик/агрегатор) → без изменений.
  describe 'Origin/Referer (rev #230)' do
    it 'прод-хост + Origin со staging → auto_test' do
      get chat_conversation_path(format: :json),
          headers: { 'HOST' => 'victory62.org', 'Origin' => 'https://staging.victory62.org' }
      expect(response).to have_http_status(:ok)

      expect(conversation.reload.metadata['auto_test']).to be(true)
    end

    it 'прод-хост + Referer с localhost → auto_test' do
      get chat_conversation_path(format: :json),
          headers: { 'HOST' => 'victory62.org', 'Referer' => 'http://localhost:3000/' }
      expect(response).to have_http_status(:ok)

      expect(conversation.reload.metadata['auto_test']).to be(true)
    end

    it 'прод-хост + внешний Referer (поисковик) → боевой, без auto_test' do
      get chat_conversation_path(format: :json),
          headers: { 'HOST' => 'victory62.org', 'Referer' => 'https://www.google.com/search?q=test' }
      expect(response).to have_http_status(:ok)

      expect(conversation.reload.metadata['auto_test']).not_to be(true)
      expect(conversation).not_to be_lead_test_mode
    end

    it 'прод-хост + прод Origin/Referer → боевой, без auto_test' do
      get chat_conversation_path(format: :json),
          headers: { 'HOST' => 'victory62.org', 'Origin' => 'https://victory62.org',
                     'Referer' => 'https://www.victory62.org/' }
      expect(response).to have_http_status(:ok)

      expect(conversation.reload.metadata['auto_test']).not_to be(true)
    end
  end

  it 'POST сообщения с staging-хоста тоже помечает сессию' do
    get chat_conversation_path(format: :json), headers: { 'HOST' => 'staging.victory62.org' }

    post chat_conversation_messages_path,
         params: { body: 'прогон с staging' }.to_json,
         headers: { 'CONTENT_TYPE' => 'application/json', 'HOST' => 'staging.victory62.org' }

    expect(response).to have_http_status(:created)
    expect(conversation.reload.metadata['auto_test']).to be(true)
  end

  # Rev #230, round 3: sticky-флаг крана. Диалог ПРИНЯТ под краном — контроллер
  # фиксирует metadata['force_test']; кран снят — боевой прогон всё равно
  # тестовый, иначе фоновые задачи по этой сессии ушли бы в боевой чат.
  describe 'ENV-кран — sticky-снапшот (rev #230)' do
    it 'под краном → metadata.force_test; кран снят — флаг остаётся' do
      ENV['SITE_CHATBOT_FORCE_TEST'] = '1'
      open_chat(host: 'victory62.org')
      expect(conversation.reload.metadata['force_test']).to be(true)
      expect(conversation).to be_lead_test_mode

      ENV.delete('SITE_CHATBOT_FORCE_TEST')
      open_chat(host: 'victory62.org')

      expect(conversation.reload.metadata['force_test']).to be(true)
      expect(conversation).to be_lead_test_mode
    end

    it 'без крана флаг не появляется' do
      open_chat(host: 'victory62.org')
      expect(conversation.reload.metadata['force_test']).not_to be(true)
    end
  end

  it 'флаг не снимается: повторный заход с прод-хоста оставляет auto_test' do
    open_chat(host: 'staging.victory62.org')
    expect(conversation.reload.metadata['auto_test']).to be(true)

    open_chat(host: 'victory62.org')

    expect(conversation.reload.metadata['auto_test']).to be(true)
  end
end
