# frozen_string_literal: true

require 'rails_helper'

# Тест-контур чат-виджета — довоз фич из закрытого PR #230 (issue #249).
# Три сигнала сходятся к одному маркеру metadata['test_probe']:
#   1. probe-cookie из #228 (секретная ссылка) — не проверяем здесь, см.
#      visitor_identity_spec.rb;
#   2. кран ENV SITE_CHATBOT_FORCE_TEST;
#   3. доверенные Origin/Referer (стенды *.dev.victory62.org, localhost) и
#      внутренние подсети RFC1918.
#
# Инвариант прод-безопасности: боевой домен victory62.org не входит в
# доверенные списки ни одним путём, боевой посетитель остаётся боевым.
RSpec.describe 'Chat test mode (issue #249)', type: :request do
  def open_chat(headers = {})
    get chat_conversation_path(format: :json), headers: headers
    expect(response).to have_http_status(:ok)
    Conversation.order(:id).last
  end

  around do |example|
    old_force = ENV['SITE_CHATBOT_FORCE_TEST']
    old_ips   = ENV['CHAT_TEST_TRUSTED_IPS']
    old_hosts = ENV['CHAT_TEST_TRUSTED_ORIGINS']
    old_probe = ENV['CHAT_PROBE_SECRET']
    old_admin = ENV['ADMIN_TOKEN']
    # Кран выключен по умолчанию во всех примерах, включаем точечно.
    ENV['SITE_CHATBOT_FORCE_TEST'] = nil
    ENV['ADMIN_TOKEN'] = nil
    ENV['CHAT_PROBE_SECRET'] = nil
    example.run
  ensure
    ENV['SITE_CHATBOT_FORCE_TEST'] = old_force
    ENV['CHAT_TEST_TRUSTED_IPS'] = old_ips
    ENV['CHAT_TEST_TRUSTED_ORIGINS'] = old_hosts
    ENV['CHAT_PROBE_SECRET'] = old_probe
    ENV['ADMIN_TOKEN'] = old_admin
  end

  describe 'кран SITE_CHATBOT_FORCE_TEST' do
    it 'выключен по умолчанию: боевой диалог без маркера' do
      conv = open_chat

      expect(conv.test_probe?).to be(false)
    end

    it 'ENV=1 переводит сайт-чат в тестовый контур' do
      ENV['SITE_CHATBOT_FORCE_TEST'] = '1'
      conv = open_chat

      expect(conv.test_probe?).to be(true)
      expect(conv.metadata['test_reason']).to eq('force_env')
    end

    it 'читается на каждый запрос: после выключения новые диалоги боевые' do
      ENV['SITE_CHATBOT_FORCE_TEST'] = '1'
      test_conv = open_chat
      ENV['SITE_CHATBOT_FORCE_TEST'] = '0'
      live_conv = open_chat(visitor_off_then_on)

      expect(test_conv.test_probe?).to be(true)
      expect(live_conv.test_probe?).to be(false)
    end

    it 'маркер дорисовывается в уже открытый диалог (кран подняли посреди разговора)' do
      conv = open_chat(visitor_off_then_on)
      expect(conv.test_probe?).to be(false)

      ENV['SITE_CHATBOT_FORCE_TEST'] = '1'
      get chat_conversation_path(format: :json)
      expect(response).to have_http_status(:ok)

      expect(conv.reload.test_probe?).to be(true)
      expect(conv.metadata['test_reason']).to eq('force_env')
    end

    it 'значения true/yes/on тоже включают кран' do
      %w[true yes on].each do |value|
        ChatMessage.delete_all
        Conversation.delete_all
        ENV['SITE_CHATBOT_FORCE_TEST'] = value
        conv = open_chat
        expect(conv.test_probe?).to be(true), "значение #{value.inspect} должно включать кран"
      end
    end

    it 'произвольное значение кран не включает' do
      ENV['SITE_CHATBOT_FORCE_TEST'] = 'maybe'
      conv = open_chat

      expect(conv.test_probe?).to be(false)
    end
  end

  describe 'авто-тест по Origin/Referer' do
    it 'Origin стендового домена *.dev.victory62.org переводит диалог в тест' do
      conv = open_chat('Origin' => 'https://staging.dev.victory62.org')

      expect(conv.test_probe?).to be(true)
      expect(conv.metadata['test_reason']).to eq('trusted_origin')
    end

    it 'Referer стендового домена — fallback, когда Origin не задан' do
      conv = open_chat('Referer' => 'https://staging.dev.victory62.org/properties')

      expect(conv.test_probe?).to be(true)
    end

    it 'Origin авторитетен: чужой Origin + доверенный Referer = боевой диалог' do
      conv = open_chat('Origin' => 'https://victory62.org',
                       'Referer' => 'https://staging.dev.victory62.org/')

      expect(conv.test_probe?).to be(false)
    end

    it 'localhost считается стендом' do
      conv = open_chat('Origin' => 'http://localhost:3000')

      expect(conv.test_probe?).to be(true)
    end

    it 'боевой Origin victory62.org не переводит диалог в тест' do
      conv = open_chat('Origin' => 'https://victory62.org')

      expect(conv.test_probe?).to be(false)
    end

    it 'поддельный поддомен evil-dev.victory62.org не совпадает со стендовым суффиксом' do
      conv = open_chat('Origin' => 'https://evil-dev.victory62.org')

      expect(conv.test_probe?).to be(false)
    end

    it 'CHAT_TEST_TRUSTED_ORIGINS расширяет список доверенных' do
      ENV['CHAT_TEST_TRUSTED_ORIGINS'] = 'demo.example.com'
      conv = open_chat('Origin' => 'https://demo.example.com')

      expect(conv.test_probe?).to be(true)
    end

    it 'составной Origin парсится до хоста (scheme/port не мешают)' do
      conv = open_chat('Origin' => 'https://staging.dev.victory62.org:8443')

      expect(conv.test_probe?).to be(true)
    end
  end

  describe 'авто-тест по IP' do
    it 'запрос из RFC1918-подсети переводит диалог в тест' do
      conv = open_chat('REMOTE_ADDR' => '10.10.0.5')

      expect(conv.test_probe?).to be(true)
      expect(conv.metadata['test_reason']).to eq('trusted_ip')
    end

    it '172.16/12 — тоже внутренняя подсеть' do
      conv = open_chat('REMOTE_ADDR' => '172.18.0.9')

      expect(conv.test_probe?).to be(true)
    end

    it 'публичный IP боевого посетителя остаётся боевым' do
      conv = open_chat('REMOTE_ADDR' => '176.104.221.64')

      expect(conv.test_probe?).to be(false)
    end

    it 'CHAT_TEST_TRUSTED_IPS расширяет подсети' do
      ENV['CHAT_TEST_TRUSTED_IPS'] = '203.0.113.0/24'
      conv = open_chat('REMOTE_ADDR' => '203.0.113.7')

      expect(conv.test_probe?).to be(true)
    end

    it 'битые CIDR в ENV не роняют чат — запись пропускается' do
      ENV['CHAT_TEST_TRUSTED_IPS'] = 'не-ip,10.99.0.1'
      conv = open_chat('REMOTE_ADDR' => '10.99.0.1')

      expect(conv.test_probe?).to be(true)
    end
  end

  describe 'тумблер 🧪 Тест-прогон (POST activate_test)' do
    let(:probe_secret) { 'test-probe-secret-123' }

    before do
      ENV['CHAT_PROBE_SECRET'] = probe_secret
    end

    def activate_test(secret, headers = {})
      post activate_test_chat_conversation_path,
           params: { probe_key: secret }.to_json,
           headers: { 'CONTENT_TYPE' => 'application/json', 'ACCEPT' => 'application/json' }.merge(headers)
    end

    it 'по верному секрету выпускает probe-cookie и закрывает старый диалог' do
      conv = open_chat
      expect(conv.test_probe?).to be(false)

      activate_test(probe_secret)
      expect(response).to have_http_status(:ok)

      # Сервер закрыл старый диалог, новый bootstrap создаст тестовый.
      expect(conv.reload.status_closed?).to be(true)
      test_conv = open_chat
      expect(test_conv.test_probe?).to be(true)
      expect(test_conv.id).not_to eq(conv.id)
    end

    it 'без секрета — 403, ничего не меняется' do
      conv = open_chat

      activate_test('wrong-secret')
      expect(response).to have_http_status(:forbidden)

      expect(conv.reload.test_probe?).to be(false)
      expect(conv.status_active?).to be(true)
    end

    it 'секрет не настроен на сервере — режим полностью выключен' do
      ENV['CHAT_PROBE_SECRET'] = nil
      ENV['ADMIN_TOKEN'] = nil

      activate_test('whatever')
      expect(response).to have_http_status(:forbidden)
    end

    it 'токен из ответа не извлекается: ответ содержит только ok' do
      activate_test(probe_secret)

      json = response.parsed_body
      expect(json).to eq('ok' => true)
      expect(response.body).not_to match(/[0-9a-f]{32}/)
    end

    # КРИТЕРИЙ ПРИЁМКИ: токен, выданный одной сессии, не переводит другую
    # в тест-режим. Cookie подписан, но подпись не делает его непереносимым:
    # переносимый артефакт в принципе существует. Реальная гарантия — от
    # конструктора #228/#229: токен не выдаётся анониму без секрета и НЕ
    # принимается из произвольного URL для подмены визита. Здесь проверяем
    # обе половины: (а) токен из ответа А не извлекается; (б) даже если
    # сессия Б завладеет строкой токена А и предъявит её через URL,
    # её собственный диалог не станет тестовым и не сольётся с диалогом А.
    it 'токен прогона одной сессии не переводит другую сессию в тест-режим' do
      # Сессия А активирует прогон по секрету.
      open_chat # гарантирует cookie у А
      activate_test(probe_secret)
      expect(response).to have_http_status(:ok)
      conv_a = open_chat
      expect(conv_a.test_probe?).to be(true)

      # (а) из ответа сервера токен не извлекается — только ok: true.
      activate_test(probe_secret)
      expect(response.parsed_body).to eq('ok' => true)
      expect(response.body).not_to match(/[0-9a-f]{32}/)

      # (б) сессия Б — независимый cookie-jar (новый анонимный визит).
      # Злоумышленник знает visitor_token А (украденная строка) и пытается
      # применить его через URL — как произвольный visitor_token, так и
      # как probe-имя: VisitorIdentity принимает токены только из
      # собственного signed-cookie, URL-параметр их не подменяет.
      session_b = Rack::Test::Session.new(Capybara.app)
      session_b.get(chat_conversation_path(format: :json), visitor_token: conv_a.visitor_token)
      expect(session_b.last_response).to have_http_status(:ok)
      conv_b = Conversation.order(:id).last
      expect(conv_b.test_probe?).to be(false)
      expect(conv_b.id).not_to eq(conv_a.id)
      expect(conv_b.visitor_token).not_to eq(conv_a.visitor_token)

      # probe-имя без секрета тоже не переводит Б в тест (issue #229).
      session_b.get(chat_conversation_path(format: :json),
                    visitor_token: 'probe-stolen', probe_key: 'no-such-secret')
      expect(session_b.last_response).to have_http_status(:ok)
      conv_b2 = Conversation.order(:id).last
      expect(conv_b2.test_probe?).to be(false)
    end

    it 'активация при уже включённом кране не ломает диалог' do
      ENV['SITE_CHATBOT_FORCE_TEST'] = '1'
      activate_test(probe_secret)
      expect(response).to have_http_status(:ok)

      conv = open_chat
      expect(conv.test_probe?).to be(true)
    end
  end

  describe 'изоляция через существующие гейты #228' do
    it 'force-тестовый диалог ставит lead_test_mode в LlmReplyJob (сквозная композиция)' do
      ENV['SITE_CHATBOT_FORCE_TEST'] = '1'
      conv = open_chat
      expect(conv.test_probe?).to be(true)

      msg = ChatMessage.create!(conversation: conv, role: :user, body: 'Сколько стоит квартира?')
      allow(Llm::ChatResponder).to receive(:new).and_return(
        instance_double(Llm::ChatResponder, call: { reply: 'ok', model: 'stub', escalate: false })
      )
      described = LlmReplyJob.new
      captured = nil
      allow(Llm::ChatResponder).to receive(:new) do |*args|
        captured = Thread.current[:lead_test_mode]
        instance_double(Llm::ChatResponder, call: { reply: 'ok', model: 'stub', escalate: false })
      end

      described.perform(conv.id, msg.id)

      expect(captured).to be(true)
      expect(Thread.current[:lead_test_mode]).to be(false)
    end

    it 'боевой диалог (публичный IP, прод-Origin) lead_test_mode не ставит' do
      conv = open_chat('Origin' => 'https://victory62.org', 'REMOTE_ADDR' => '176.104.221.64')
      expect(conv.test_probe?).to be(false)

      msg = ChatMessage.create!(conversation: conv, role: :user, body: 'Сколько стоит квартира?')
      allow(Llm::ChatResponder).to receive(:new) do |*args|
        expect(Thread.current[:lead_test_mode]).to be(false)
        instance_double(Llm::ChatResponder, call: { reply: 'ok', model: 'stub', escalate: false })
      end

      LlmReplyJob.new.perform(conv.id, msg.id)
    end
  end

  private

  # ?visitor_token=off между визитами — чтобы каждый open_chat создавал
  # НОВЫЙ диалог (своё поведение VisitorIdentity), а не переиспользовал
  # уже открытый предыдущим примером.
  def visitor_off_then_on
    get chat_conversation_path(format: :json), params: { visitor_token: 'off' }
    {}
  end
end
