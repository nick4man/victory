# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::ClientBot::TextIntakeProcessor do
  let(:client_tg_id) { 200_001 }

  let(:base_msg) do
    {
      'message_id' => 1,
      'from' => { 'id' => client_tg_id, 'username' => 'client1', 'first_name' => 'Клиент', 'is_bot' => false },
      'chat' => { 'id' => client_tg_id, 'type' => 'private' },
      'text' => 'хочу квартиру 2-комн в Канищево до 8 млн'
    }
  end

  describe '.applies?' do
    it 'true для private DM от не-staff с text' do
      expect(described_class.applies?(base_msg)).to be(true)
    end

    it 'false если staff (TelegramUser exists)' do
      TelegramUser.create!(tg_user_id: client_tg_id, first_name: 'Staff', status: 'active')
      expect(described_class.applies?(base_msg)).to be(false)
    end

    it 'false для group chat' do
      msg = base_msg.merge('chat' => { 'id' => -123, 'type' => 'supergroup' })
      expect(described_class.applies?(msg)).to be(false)
    end

    it 'false для пустого text' do
      msg = base_msg.merge('text' => '   ')
      expect(described_class.applies?(msg)).to be(false)
    end

    it 'false для slash-команды' do
      msg = base_msg.merge('text' => '/help')
      expect(described_class.applies?(msg)).to be(false)
    end

    it 'false для бота-отправителя' do
      msg = base_msg.merge('from' => base_msg['from'].merge('is_bot' => true))
      expect(described_class.applies?(msg)).to be(false)
    end

    it 'false для blank from.id' do
      msg = base_msg.merge('from' => { 'id' => nil })
      expect(described_class.applies?(msg)).to be(false)
    end
  end

  describe '#call' do
    let(:tg_client) { instance_double(::Telegram::Client, send_message: { 'message_id' => 100 }) }

    # Stub IntentClassifier через allow.
    def stub_intent(intent:, confidence: 0.85)
      result = Llm::IntentClassifier::Result.new(
        intent: intent, confidence: confidence, reasoning: 'stub', model: 'stub-model', error: nil
      )
      allow(::Llm::IntentClassifier).to receive(:call).and_return(result)
    end

    # Phase 15-side — отключим redis rate-limit для большинства тестов через fail-open
    before { allow_any_instance_of(described_class).to receive(:redis_connection).and_return(nil) }

    context 'spam' do
      before { stub_intent(intent: 'spam') }

      it 'silent drop без reply' do
        result = described_class.new(base_msg, client: tg_client).call
        expect(result).to eq(:dropped_spam)
        expect(tg_client).not_to have_received(:send_message)
      end
    end

    context 'abuse' do
      before { stub_intent(intent: 'abuse') }

      it 'silent drop' do
        result = described_class.new(base_msg, client: tg_client).call
        expect(result).to eq(:dropped_spam)
        expect(tg_client).not_to have_received(:send_message)
      end
    end

    context 'test intent (probing message)' do
      before { stub_intent(intent: 'test') }

      it 'soft greeting reply' do
        result = described_class.new(base_msg, client: tg_client).call
        expect(result).to eq(:soft_greeting)
        expect(tg_client).to have_received(:send_message).with(
          a_string_matching(/Здравствуйте.*бот АН «Виктори»/), hash_including(:chat_id)
        )
      end
    end

    context 'low-confidence unclear' do
      before { stub_intent(intent: 'unclear', confidence: 0.3) }

      it 'soft greeting (confidence < 0.5)' do
        result = described_class.new(base_msg, client: tg_client).call
        expect(result).to eq(:soft_greeting)
      end
    end

    context 'actionable inquiry' do
      before do
        stub_intent(intent: 'inquiry', confidence: 0.9)
        allow(::Lead::Intake).to receive(:call).and_return(
          { lead_event: instance_double('LeadEvent', metadata: { 'returning_client' => false }) }
        )
      end

      it 'делает intake + confirm reply' do
        result = described_class.new(base_msg, client: tg_client).call
        expect(result).to eq(:announced)
        expect(::Lead::Intake).to have_received(:call).with(source: 'tg_dm', payload: hash_including(:text, :tg_user_id))
        expect(tg_client).to have_received(:send_message).with(
          a_string_matching(/Заявка принята/), hash_including(:chat_id)
        )
      end

      it 'persisted text проходит через PII redactor' do
        described_class.new(base_msg.merge('text' => 'мой телефон +79991234567'), client: tg_client).call
        expect(::Lead::Intake).to have_received(:call) do |source:, payload:|
          expect(source).to eq('tg_dm')
          expect(payload[:text]).not_to include('+79991234567')
        end
      end
    end

    context 'actionable appointment vs question — разные reply texts' do
      it 'appointment → «Принято! Передал агенту»' do
        stub_intent(intent: 'appointment', confidence: 0.9)
        allow(::Lead::Intake).to receive(:call).and_return(
          { lead_event: instance_double('LeadEvent', metadata: {}) }
        )
        described_class.new(base_msg, client: tg_client).call
        expect(tg_client).to have_received(:send_message).with(a_string_matching(/Принято!.*согласовать время/), anything)
      end

      it 'question → «Спасибо за вопрос»' do
        stub_intent(intent: 'question', confidence: 0.9)
        allow(::Lead::Intake).to receive(:call).and_return(
          { lead_event: instance_double('LeadEvent', metadata: {}) }
        )
        described_class.new(base_msg, client: tg_client).call
        expect(tg_client).to have_received(:send_message).with(a_string_matching(/Спасибо за вопрос/), anything)
      end
    end

    context 'returning client (metadata returning_client=true)' do
      before do
        stub_intent(intent: 'inquiry', confidence: 0.9)
        allow(::Lead::Intake).to receive(:call).and_return(
          { lead_event: instance_double('LeadEvent', metadata: { 'returning_client' => true }) }
        )
      end

      it 'reply «Спасибо, что вернулись!»' do
        described_class.new(base_msg, client: tg_client).call
        expect(tg_client).to have_received(:send_message).with(
          a_string_matching(/Спасибо, что вернулись/), anything
        )
      end
    end

    context 'Lead::Intake возвращает nil' do
      before do
        stub_intent(intent: 'inquiry', confidence: 0.9)
        allow(::Lead::Intake).to receive(:call).and_return(nil)
      end

      it 'возвращает :intake_failed без crash' do
        result = described_class.new(base_msg, client: tg_client).call
        expect(result).to eq(:intake_failed)
      end
    end

    context 'StandardError во время processing' do
      before do
        stub_intent(intent: 'inquiry', confidence: 0.9)
        allow(::Lead::Intake).to receive(:call).and_raise(StandardError.new('intake crashed'))
      end

      it 'возвращает :error без проброса exception (soft-fail)' do
        result = described_class.new(base_msg, client: tg_client).call
        expect(result).to eq(:error)
      end
    end
  end
end
