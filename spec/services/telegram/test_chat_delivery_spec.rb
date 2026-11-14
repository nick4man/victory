# frozen_string_literal: true

require 'rails_helper'

# Интеграционный прогон с реальным Telegram (issue #214).
#
# Гоняется только там, где заданы оба ENV — локально тестировщик экспортирует
# их сам, в CI они приходят из GitHub Secrets (TELEGRAM_TEST_BOT_TOKEN —
# токен ТЕСТОВОГО бота, не продового):
#
#   TELEGRAM_TEST_BOT_TOKEN=… TELEGRAM_TEST_CHAT_ID=-100… \
#     bin/rb --db bundle exec rspec spec/services/telegram/test_chat_delivery_spec.rb
#
# Без секретов spec skip'ается. WebMock.disable! — глобальное отключение:
# stub'ы из spec/support/external_services.rb перехватывают быстрее
# allow_net_connect!, поэтому живой прогон требует полного выключения.
# enable! в after гарантированно возвращает изоляцию остальным примерам.
RSpec.describe 'Telegram test chat delivery (integration)' do
  let(:bot_token) { ENV['TELEGRAM_TEST_BOT_TOKEN'].presence }
  let(:chat_id)   { ENV['TELEGRAM_TEST_CHAT_ID'].presence }

  before do
    skip 'TELEGRAM_TEST_BOT_TOKEN/TELEGRAM_TEST_CHAT_ID не заданы — см. заголовок spec' unless bot_token && chat_id

    WebMock.disable!

    # Токен может быть прописан в окружении, но отозван/недействителен —
    # в таком случае живой прогон невозможен, и спека skip'ается, а не падает.
    begin
      Telegram::Client.new(token: bot_token).get_me
    rescue Telegram::Client::Error => e
      skip "TELEGRAM_TEST_BOT_TOKEN недействителен (#{e.message}) — см. заголовок spec"
    end
  end

  after do
    WebMock.enable!
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  it 'тест-лид публикуется в тестовый чат живым вызовом Bot API' do
    inquiry = create(:inquiry, source: 'site_form', metadata: { 'test' => true })
    lead = LeadEvent.create!(
      lead_ref:         inquiry,
      source:           'site_form',
      tg_chat_id:       chat_id.to_i,
      anchor_topic_key: 'dispatcher',
      current_stage:    'new',
      metadata:         { 'name' => 'Интеграционный прогон', 'phone' => '+790****0000',
                          'summary' => 'issue #214: доставка в тестовый чат', 'test' => true }
    )

    client = Telegram::Client.new(token: bot_token)
    begin
      announcer = Telegram::WorkBot::LeadAnnouncer.new(lead, client: client)

      expect(announcer.call).to be(true)
      expect(lead.reload.anchor_message_id).to be_present

      text = announcer.format_card_text
      expect(text).to include('🧪 <b>ТЕСТ</b>')
      expect(text).to include('Интеграционный прогон')

      # Доказательство живого вызова: stub из external_services.rb возвращает
      # chat.id рабочей группы (-1003779115845) и message_id 1 — любой другой
      # ответ (chat.id тестового чата) значит, что запрос ушёл реально.
      probe = client.send_message('🧪 issue #214 live-check', chat_id: chat_id.to_i)
      expect(probe.dig('chat', 'id')).to eq(chat_id.to_i)
      begin
        client.delete_message(chat_id: chat_id.to_i, message_id: probe['message_id'])
      rescue Telegram::Client::Error => e
        Rails.logger.warn("[test_chat_delivery_spec] cleanup probe delete failed: #{e.message}")
      end
    ensure
      # Карточка — одноразовая: убираем её из тестового чата, чтобы не копить мусор.
      begin
        client.delete_message(chat_id: chat_id.to_i, message_id: lead.anchor_message_id) if lead.anchor_message_id
      rescue Telegram::Client::Error => e
        Rails.logger.warn("[test_chat_delivery_spec] cleanup delete_message failed: #{e.message}")
      end
    end
  end
end
