# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::MailFailureAlert do
  let!(:director) do
    TelegramUser.create!(tg_user_id: 40_001, first_name: 'Оксана',
                         role: 'director', is_manager: true, status: 'active', dm_chat_id: 40_001)
  end

  let(:tg_client) { instance_double(Telegram::Client) }
  let(:exception) { Net::SMTPAuthenticationError.new('535 5.7.0 Net dostupa na vashem tarife') }

  let(:mail_job) do
    {
      'class' => 'ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper',
      'wrapped' => 'ActionMailer::MailDeliveryJob',
      'retry_count' => 2,
      'args' => [{
        'arguments' => ['TelegramAuthMailer', 'verification_code', 'deliver_now',
                        { 'args' => [{ 'email' => 'agent@victory62.org', 'code' => '424242' }] }]
      }]
    }
  end

  before do
    allow(Telegram::Client).to receive(:new).and_return(tg_client)
    allow(tg_client).to receive(:send_message).and_return({ 'message_id' => 1 })
    allow(Telegram::AlertThrottle).to receive_messages(allow?: true, suppressed_count: 0)
  end

  describe '.call' do
    it 'шлёт DM директору о потерянном письме' do
      expect(described_class.call(job: mail_job, exception: exception)).to be(true)
      expect(tg_client).to have_received(:send_message).with(
        a_string_including('Письмо не доставлено'), hash_including(chat_id: 40_001)
      )
    end

    it 'указывает адресата и мейлер, чтобы было понятно что именно пропало' do
      described_class.call(job: mail_job, exception: exception)

      expect(tg_client).to have_received(:send_message).with(
        a_string_including('agent@victory62.org').and(a_string_including('TelegramAuthMailer#verification_code')),
        anything
      )
    end

    it 'игнорирует непочтовые джобы' do
      job = mail_job.merge('wrapped' => 'EmbedPropertyJob')

      expect(described_class.call(job: job, exception: exception)).to be(false)
      expect(tg_client).not_to have_received(:send_message)
    end

    it 'молчит когда троттл закрыт — при лежащем SMTP умирают десятки писем' do
      allow(Telegram::AlertThrottle).to receive(:allow?).and_return(false)

      expect(described_class.call(job: mail_job, exception: exception)).to be(false)
      expect(tg_client).not_to have_received(:send_message)
    end

    it 'троттлит по связке джоба + класс ошибки на час' do
      described_class.call(job: mail_job, exception: exception)

      expect(Telegram::AlertThrottle).to have_received(:allow?).with(
        key: 'mail_failure:ActionMailer::MailDeliveryJob:Net::SMTPAuthenticationError',
        ttl: 1.hour
      )
    end

    it 'ловит собственные джобы, которые шлют почту сами' do
      job = { 'class' => 'InquiryNotificationJob', 'args' => [90] }

      expect(described_class.call(job: job, exception: exception)).to be(true)
    end

    it 'не падает когда получателей алерта нет' do
      director.update!(status: 'inactive')

      expect(described_class.call(job: mail_job, exception: exception)).to be(false)
      expect(tg_client).not_to have_received(:send_message)
    end

    it 'не роняет обработчик смерти если Telegram недоступен' do
      allow(tg_client).to receive(:send_message).and_raise(StandardError, 'TG down')

      expect { described_class.call(job: mail_job, exception: exception) }.not_to raise_error
    end
  end
end
