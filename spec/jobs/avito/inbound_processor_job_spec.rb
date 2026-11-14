# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Avito::InboundProcessorJob, type: :job do
  let(:payload) do
    {
      'payload' => {
        'type' => 'message',
        'value' => {
          'id' => 'msg_123',
          'chat_id' => 'chat_456',
          'author_id' => 987_654,
          'user_id' => 123_456,
          'item_id' => 111_222_333,
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

  it 'вызывает Avito::InboundProcessor' do
    expect { described_class.new.perform(payload) }
      .to change(AvitoMessage, :count).by(1)
      .and change(AvitoWebhookAck, :count).by(1)
  end

  it 'переваривает JSON-строку' do
    expect { described_class.new.perform(payload.to_json) }
      .to change(AvitoMessage, :count).by(1)
  end

  it 'пробрасывает ошибки для Sidekiq retry' do
    allow(Avito::InboundProcessor).to receive(:new).and_raise(StandardError, 'boom')

    expect { described_class.new.perform(payload) }.to raise_error(StandardError, 'boom')
  end
end
