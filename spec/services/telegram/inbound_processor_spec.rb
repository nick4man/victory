# frozen_string_literal: true

require 'rails_helper'

# BOTTLENECK — порядок веток диспетчера есть фактическая спецификация
# приоритетов, и до этого файла он не был закрыт ни одним тестом. План меняет
# гейт голосовой ветки, поэтому оставляет после себя тест, который поймает
# и перестановку веток, и случайный возврат старого гейта.
RSpec.describe Telegram::InboundProcessor do
  let!(:agent) do
    TelegramUser.create!(tg_user_id: 501, role: 'agent', first_name: 'Оксана',
                         is_manager: false, status: 'active', dm_chat_id: 501)
  end

  def voice_update(from_id:, update_id: rand(1..(10**9)))
    { 'update_id' => update_id,
      'message' => { 'message_id' => 31, 'from' => { 'id' => from_id },
                     'chat' => { 'id' => from_id, 'type' => 'private' },
                     'voice' => { 'file_id' => 'AwACAgIAAx' } } }
  end

  it 'голос агента в личке попадает в VoiceIntakeProcessor, а не в клиентскую ветку' do
    processor = instance_double(Telegram::WorkBot::VoiceIntakeProcessor, call: :show_report)
    expect(Telegram::WorkBot::VoiceIntakeProcessor).to receive(:new).and_return(processor)
    expect(Telegram::ClientBot::TextIntakeProcessor).not_to receive(:new)

    expect(described_class.new(voice_update(from_id: 501)).call).to eq(:show_report)
  end

  it 'повторный update_id не обрабатывается второй раз' do
    update = voice_update(from_id: 501, update_id: 777_001)
    allow(Telegram::WorkBot::VoiceIntakeProcessor).to receive(:new)
      .and_return(instance_double(Telegram::WorkBot::VoiceIntakeProcessor, call: :show_report))

    expect(described_class.new(update).call).to eq(:show_report)
    expect(described_class.new(update).call).to eq(:duplicate)
  end

  describe 'текстовый ответ мастеру' do
    def text_update(text)
      { 'update_id' => rand(1..(10**9)),
        'message' => { 'message_id' => 32, 'from' => { 'id' => 501 },
                       'chat' => { 'id' => 501, 'type' => 'private' }, 'text' => text } }
    end

    before do
      agent.set_pending_action!(type: 'wizard', data: { flow: 'task', step: 'title', ctx: { lead: '1' } })
    end

    it 'при активном мастере уходит в Wizard::Engine, а не в LLM-Q&A' do
      engine = instance_double(Telegram::WorkBot::Wizard::Engine, text: :handled)
      expect(Telegram::WorkBot::Wizard::Engine).to receive(:new).and_return(engine)
      expect(Telegram::WorkBot::DmQnaHandler).not_to receive(:call)

      expect(described_class.new(text_update('Позвонить клиенту')).call).to eq(:handled)
    end

    it 'команду не перехватывает — передумавший сотрудник пишет /команду' do
      expect(Telegram::WorkBot::Wizard::Engine).not_to receive(:new)
      allow(Telegram::WorkBot::Router).to receive(:new)
        .and_return(instance_double(Telegram::WorkBot::Router, call: :handled))

      described_class.new(text_update('/help')).call
    end
  end
end
