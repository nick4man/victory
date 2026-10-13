# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Sandbox::CodespaceReadyJob do
  let(:tg_client) { instance_double(Telegram::Client, send_message: { 'message_id' => 1 }) }
  let(:chat_id) { 500_201 }

  before do
    allow(Telegram::Client).to receive(:new).and_return(tg_client)
    allow(described_class).to receive(:perform_in)
  end

  def status(state) = Sandbox::Codespace::Status.new(name: 'cs', state: state)

  it 'поднялась — зовёт тестировать и больше не проверяет' do
    allow(Sandbox::Codespace).to receive(:status).and_return(status('Available'))

    described_class.new.perform(chat_id)

    expect(tg_client).to have_received(:send_message).with(a_string_including('поднялась'), hash_including(chat_id: chat_id))
    expect(described_class).not_to have_received(:perform_in)
  end

  it 'ещё поднимается — проверит снова, не занимая воркер' do
    allow(Sandbox::Codespace).to receive(:status).and_return(status('Starting'))

    described_class.new.perform(chat_id)

    expect(described_class).to have_received(:perform_in).with(described_class::DELAY, chat_id, 2, nil)
    expect(tg_client).not_to have_received(:send_message)
  end

  it 'сбой GitHub на одной проверке ожидание не обрывает' do
    allow(Sandbox::Codespace).to receive(:status).and_raise(Sandbox::Codespace::Error, 'GitHub недоступен')

    described_class.new.perform(chat_id, 3)

    expect(described_class).to have_received(:perform_in).with(described_class::DELAY, chat_id, 4, nil)
  end

  it 'попытки кончились — честно говорит, что не дождались' do
    described_class.new.perform(chat_id, described_class::ATTEMPTS + 1)

    expect(tg_client).to have_received(:send_message).with(a_string_including('не поднялась'), hash_including(chat_id: chat_id))
    expect(described_class).not_to have_received(:perform_in)
  end

  it 'сбой отправки в Telegram джоб не роняет' do
    allow(Sandbox::Codespace).to receive(:status).and_return(status('Available'))
    allow(tg_client).to receive(:send_message).and_raise(Telegram::Client::Error, 'chat not found')

    expect { described_class.new.perform(chat_id) }.not_to raise_error
  end
end
