# frozen_string_literal: true

require 'rails_helper'

# Спека появилась после находки ревью 14.08.26: `edit_message_reply_markup` и
# `pin_chat_message` собирали тело запроса без явных скобок, и Ruby 3 разбирал
# пары как kwargs — `api_call` падал с ArgumentError на КАЖДОМ вызове. Оба
# метода не работали ни разу с момента появления.
#
# Снаружи это выглядело как «кнопки просто не снимаются»: вызывающая сторона
# ловила ошибку в rescue и писала warn. Спеки на вызывающих не помогали
# принципиально — `instance_double(Telegram::Client)` проверяет сигнатуру
# публичного метода, а она была корректной. Поэтому подменяем HTTP, а не
# объект под тестом: только так тело метода реально исполняется.
RSpec.describe Telegram::Client do
  subject(:client) { described_class.new(token: 'test-token') }

  let(:base) { 'https://api.telegram.org/bottest-token' }

  before { WebMock.disable_net_connect! }
  after  { WebMock.allow_net_connect! }

  def stub_ok(method)
    stub_request(:post, "#{base}/#{method}")
      .to_return(status: 200, body: { ok: true, result: true }.to_json,
                 headers: { 'Content-Type' => 'application/json' })
  end

  describe '#edit_message_reply_markup' do
    it 'доходит до Telegram, а не падает на разборе аргументов' do
      stub_ok('editMessageReplyMarkup')

      expect { client.edit_message_reply_markup(chat_id: 42, message_id: 7, reply_markup: { inline_keyboard: [] }) }
        .not_to raise_error
    end

    it 'кладёт параметры в тело запроса' do
      stub_ok('editMessageReplyMarkup')

      client.edit_message_reply_markup(chat_id: 42, message_id: 7, reply_markup: { inline_keyboard: [] })

      expect(WebMock).to have_requested(:post, "#{base}/editMessageReplyMarkup")
        .with(body: { chat_id: 42, message_id: 7, reply_markup: { inline_keyboard: [] } }.to_json)
    end
  end

  describe '#pin_chat_message' do
    it 'доходит до Telegram, а не падает на разборе аргументов' do
      stub_ok('pinChatMessage')

      expect { client.pin_chat_message(chat_id: 42, message_id: 7) }.not_to raise_error

      expect(WebMock).to have_requested(:post, "#{base}/pinChatMessage")
        .with(body: { chat_id: 42, message_id: 7, disable_notification: true }.to_json)
    end
  end

  # Контрольная пара: эти два всегда собирали тело явным хешем, и падения на
  # них никогда не было. Держим рядом, чтобы разница была видна в одном файле.
  describe '#delete_message' do
    it 'по-прежнему работает' do
      stub_ok('deleteMessage')

      expect { client.delete_message(chat_id: 42, message_id: 7) }.not_to raise_error
    end
  end
end
