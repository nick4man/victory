# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Avito::InboundProcessor, type: :service do
  let(:item_id) { 111_222_333 }
  let(:author_id) { 987_654 }
  let(:user_id) { 123_456 }
  let(:message_id) { 'msg_abc123' }

  let(:payload) do
    {
      'payload' => {
        'type' => 'message',
        'value' => {
          'id' => message_id,
          'chat_id' => 'chat_456',
          'chat_type' => 'u2i',
          'author_id' => author_id,
          'user_id' => user_id,
          'item_id' => item_id,
          'type' => 'text',
          'created' => 1_700_000_000,
          'content' => { 'text' => 'Можно посмотреть?' }
        }
      }
    }
  end

  before do
    stub_request(:post, %r{https://api\.telegram\.org/bot.+/sendMessage})
      .to_return(status: 200, body: { ok: true, result: { message_id: 42 } }.to_json)
  end

  it 'сохраняет сообщение, маршрутизирует в Telegram и возвращает :routed' do
    result = described_class.new(payload).call

    expect(result).to eq(:routed)
    expect(AvitoMessage.count).to eq(1)
    expect(AvitoWebhookAck.count).to eq(1)
    expect(AvitoMessage.first.message_id).to eq(message_id)
    expect(WebMock).to have_requested(:post, %r{api\.telegram\.org/.+/sendMessage}).once
  end

  context 'когда объект найден по external_source=avito' do
    let!(:property) { create(:property, external_source: 'avito', external_id: item_id.to_s) }

    it 'связывает сообщение с объектом' do
      described_class.new(payload).call

      expect(AvitoMessage.first.property).to eq(property)
    end
  end

  context 'когда сообщение дублируется' do
    before { described_class.new(payload).call }

    it 'второй раз возвращает :duplicate и не создаёт дубликат' do
      result = described_class.new(payload).call

      expect(result).to eq(:duplicate)
      expect(AvitoMessage.count).to eq(1)
    end
  end

  context 'когда сообщение исходящее (author_id == user_id)' do
    let(:author_id) { user_id }

    it 'сохраняет, но не маршрутизирует' do
      result = described_class.new(payload).call

      expect(result).to eq(:ignored)
      expect(AvitoMessage.count).to eq(1)
      expect(WebMock).not_to have_requested(:post, %r{api\.telegram\.org})
    end
  end

  context 'когда объект не найден' do
    it 'маршрутизирует с упоминанием item_id' do
      described_class.new(payload).call

      expect(AvitoMessage.first.property).to be_nil
      expect(WebMock).to have_requested(:post, %r{api\.telegram\.org/.+/sendMessage}).once
    end
  end

  context 'когда payload без сообщения' do
    let(:payload) { { 'payload' => { 'type' => 'typing' } } }

    it 'возвращает :ignored' do
      expect(described_class.new(payload).call).to eq(:ignored)
    end
  end

  context 'когда сообщение с изображением' do
    let(:payload) do
      {
        'payload' => {
          'type' => 'message',
          'value' => {
            'id' => message_id,
            'chat_id' => 'chat_456',
            'author_id' => author_id,
            'user_id' => user_id,
            'item_id' => item_id,
            'type' => 'image',
            'created' => 1_700_000_000,
            'content' => {
              'image' => {
                'sizes' => {
                  '1280x960' => 'https://example.com/img_1280.jpg',
                  '640x480' => 'https://example.com/img_640.jpg'
                }
              }
            }
          }
        }
      }
    end

    before do
      stub_request(:post, %r{https://api\.telegram\.org/bot.+/sendPhoto})
        .to_return(status: 200, body: { ok: true, result: { message_id: 43 } }.to_json)
    end

    it 'отправляет фото в Telegram' do
      described_class.new(payload).call

      expect(WebMock).to have_requested(:post, %r{api\.telegram\.org/.+/sendPhoto}).once
    end
  end
end
