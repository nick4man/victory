# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Webhooks::TelegramTest', type: :request do
  let(:payload) do
    { 'update_id' => 1,
      'message' => { 'chat' => { 'id' => 111, 'type' => 'private' }, 'from' => { 'id' => 111 }, 'text' => '/cards' } }
  end

  before do
    stub_const('ENV', ENV.to_h.merge('TELEGRAM_TEST_BOT_TOKEN' => 'test-token', 'TELEGRAM_TEST_WEBHOOK_SECRET' => 's3cret'))
    allow(Telegram::InboundProcessorJob).to receive(:perform_async)
  end

  def post_update(secret)
    post '/webhooks/telegram_test', params: payload.to_json,
                                    headers: { 'CONTENT_TYPE' => 'application/json',
                                               'X-Telegram-Bot-Api-Secret-Token' => secret }
  end

  it 'верный секрет — апдейт уходит в обработку от имени тестового бота' do
    post_update('s3cret')

    expect(response).to have_http_status(:ok)
    expect(Telegram::InboundProcessorJob).to have_received(:perform_async).with(payload, 'test')
  end

  it 'неверный или пустой секрет — 403 без обработки' do
    post_update('wrong')
    expect(response).to have_http_status(:forbidden)

    post_update('')
    expect(response).to have_http_status(:forbidden)
    expect(Telegram::InboundProcessorJob).not_to have_received(:perform_async)
  end

  it 'секрет не настроен — вход закрыт, а не открыт' do
    stub_const('ENV', ENV.to_h.merge('TELEGRAM_TEST_BOT_TOKEN' => 'test-token', 'TELEGRAM_TEST_WEBHOOK_SECRET' => nil))

    post_update('')

    expect(response).to have_http_status(:forbidden)
  end
end
