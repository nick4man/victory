# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::BotContext do
  before do
    stub_const('ENV', ENV.to_h.merge('TELEGRAM_BOT_TOKEN' => 'main-token', 'TELEGRAM_TEST_BOT_TOKEN' => 'test-token'))
  end

  def stub_send(token)
    stub_request(:post, "https://api.telegram.org/bot#{token}/sendMessage")
      .to_return(body: { ok: true, result: { message_id: 7 } }.to_json)
  end

  it 'вне контекста клиент говорит от основного бота' do
    request = stub_send('main-token')

    Telegram::Client.new.send_message('привет', chat_id: 111)

    expect(request).to have_been_requested
  end

  it 'внутри тестового контекста — от тестового, и контекст не протекает наружу' do
    request = stub_send('test-token')

    described_class.within('test') { Telegram::Client.new.send_message('привет', chat_id: 111) }

    expect(request).to have_been_requested
    expect(described_class.test?).to be(false)
  end

  it 'тестовый бот не пишет в группы — отказ до запроса в Telegram' do
    described_class.within('test') do
      expect { Telegram::Client.new.send_message('в группу', chat_id: -1_003_779_115_845) }
        .to raise_error(Telegram::Client::GroupChatForbidden)
    end

    expect(a_request(:post, /api\.telegram\.org/)).not_to have_been_made
  end

  it 'основной бот в группы пишет как раньше' do
    request = stub_send('main-token')

    Telegram::Client.new.send_message('в группу', chat_id: -1_003_779_115_845)

    expect(request).to have_been_requested
  end

  it 'тестовый бот не пишет в чат с нечисловым chat_id — fail closed, а не .to_i == 0' do
    described_class.within('test') do
      expect { Telegram::Client.new.send_message('в канал', chat_id: '@some_channel') }
        .to raise_error(Telegram::Client::GroupChatForbidden)
    end

    expect(a_request(:post, /api\.telegram\.org/)).not_to have_been_made
  end

  it 'тестовый бот пишет в личку по строковому numeric chat_id' do
    request = stub_send('test-token')

    described_class.within('test') { Telegram::Client.new.send_message('привет', chat_id: '111') }

    expect(request).to have_been_requested
  end

  it 'TELEGRAM_BOT_TOKEN совпал с TELEGRAM_TEST_BOT_TOKEN — основной бот вне контекста всё равно пишет в группы' do
    stub_const('ENV', ENV.to_h.merge('TELEGRAM_BOT_TOKEN' => 'same-token', 'TELEGRAM_TEST_BOT_TOKEN' => 'same-token'))
    request = stub_send('same-token')

    Telegram::Client.new.send_message('в группу', chat_id: -1_003_779_115_845)

    expect(request).to have_been_requested
  end

  it 'неизвестный бот — ошибка, а не тихий откат на основной' do
    expect { described_class.within('prod') { nil } }.to raise_error(ArgumentError, /prod/)
  end

  it 'токен тестового бота не задан — клиент не создаётся' do
    stub_const('ENV', ENV.to_h.merge('TELEGRAM_TEST_BOT_TOKEN' => nil))

    described_class.within('test') do
      expect { Telegram::Client.new }.to raise_error(Telegram::Client::Error, /TELEGRAM_TEST_BOT_TOKEN/)
    end
  end

  it 'джобы по умолчанию работают от основного бота — контекст сам не переносится' do
    middleware = Sidekiq.default_configuration.client_middleware.entries.map { |entry| entry.klass.to_s }
    expect(middleware).not_to include(a_string_including('CurrentAttributes'))
  end
end
