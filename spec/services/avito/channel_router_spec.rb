# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Avito::ChannelRouter, type: :service do
  let(:property) { create(:property, external_source: 'avito', external_id: '111222333') }
  let(:message) do
    create(:avito_message,
           property: property,
           item_id: 111_222_333,
           content_type: 'text',
           content_text: 'Можно посмотреть?')
  end

  before do
    stub_request(:post, %r{https://api\.telegram\.org/bot.+/sendMessage})
      .to_return(status: 200, body: { ok: true, result: { message_id: 42 } }.to_json)
  end

  it 'отправляет текстовое сообщение в Telegram' do
    described_class.new(message).call

    expect(message.reload.routed_at).to be_present
    expect(WebMock).to have_requested(:post, %r{api\.telegram\.org/.+/sendMessage})
      .with(body: /Можно посмотреть\?/)
  end

  it 'экранирует HTML-символы в динамическом тексте' do
    message.update!(content_text: '5 < 10 && 20 > 15')
    property.update!(title: 'Квартира <b>люкс</b> & co')

    described_class.new(message).call

    expect(WebMock).to have_requested(:post, %r{api\.telegram\.org/.+/sendMessage})
      .with(body: /5 &lt; 10 &amp;&amp; 20 &gt; 15/)
      .with(body: /Квартира &lt;b&gt;люкс&lt;\/b&gt; &amp; co/)
  end

  it 'использует AVITO_TELEGRAM_CHAT_ID если задан' do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('AVITO_TELEGRAM_CHAT_ID').and_return('-999')

    described_class.new(message).call

    expect(WebMock).to have_requested(:post, %r{api\.telegram\.org/.+/sendMessage})
      .with(body: /"chat_id":"-999"/)
  end

  context 'когда изображение' do
    let(:message) do
      create(:avito_message,
             property: property,
             item_id: 111_222_333,
             content_type: 'image',
             content_text: 'Фото объекта',
             payload: {
               'content' => {
                 'image' => {
                   'sizes' => {
                     '1280x960' => 'https://example.com/img.jpg'
                   }
                 }
               }
             })
    end

    before do
      stub_request(:post, %r{https://api\.telegram\.org/bot.+/sendPhoto})
        .to_return(status: 200, body: { ok: true, result: { message_id: 43 } }.to_json)
    end

    it 'отправляет фото' do
      described_class.new(message).call

      expect(WebMock).to have_requested(:post, %r{api\.telegram\.org/.+/sendPhoto}).once
    end

    it 'экранирует HTML-символы в caption' do
      message.update!(content_text: '5 < 10 && 20 > 15')
      property.update!(title: 'Квартира <b>люкс</b> & co')

      described_class.new(message).call

      expect(WebMock).to have_requested(:post, %r{api\.telegram\.org/.+/sendPhoto})
        .with(body: /5 &lt; 10 &amp;&amp; 20 &gt; 15/)
        .with(body: /Квартира &lt;b&gt;люкс&lt;\/b&gt; &amp; co/)
    end
  end

  context 'когда чат не настроен' do
    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('AVITO_TELEGRAM_CHAT_ID').and_return(nil)
      allow(ENV).to receive(:[]).with('TELEGRAM_STAFF_CHAT_ID').and_return(nil)
    end

    it 'возвращает :no_chat_id и не падает' do
      expect(described_class.new(message).call).to eq(:no_chat_id)
    end
  end

  context 'когда Telegram отвечает ошибкой' do
    before do
      stub_request(:post, %r{https://api\.telegram\.org/bot.+/sendMessage})
        .to_return(status: 400, body: { ok: false, description: 'Bad Request' }.to_json)
    end

    it 'пробрасывает исключение для retry' do
      expect { described_class.new(message).call }.to raise_error(Telegram::Client::Error)
    end
  end
end
