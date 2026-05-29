# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::TaskExtractor do
  let(:with_uname) do
    TelegramUser.create!(tg_user_id: 1_000_001, tg_username: 'IrinLegaeva', first_name: 'Ирина')
  end
  let(:without_uname) do
    TelegramUser.create!(tg_user_id: 1_000_002, first_name: 'Надежда')
  end

  # Минимальный стаб OmniClient — возвращает заранее заданный JSON-ответ.
  class StubOmniClient # rubocop:disable Lint/ConstantDefinitionInBlock
    def initialize(content)
      @content = content
    end

    def complete(_messages, **_opts)
      { content: @content, model: 'stub' }
    end
  end

  describe '#staff_block' do
    it 'включает staff с tg_username в формате @uname — Имя' do
      ex = described_class.new(transcript: 'x', staff: [with_uname], client: StubOmniClient.new('{}'))
      block = ex.send(:staff_block)
      expect(block).to include('@IrinLegaeva')
      expect(block).to include('Ирина')
    end

    it 'включает staff без tg_username в формате id:N — Имя' do
      ex = described_class.new(transcript: 'x', staff: [without_uname], client: StubOmniClient.new('{}'))
      block = ex.send(:staff_block)
      expect(block).to include("id:#{without_uname.id}")
      expect(block).to include('Надежда')
      expect(block).not_to include('  • @ — ') # старый pattern (нет username) не должен появляться
    end

    it 'пустой список → плейсхолдер' do
      ex = described_class.new(transcript: 'x', staff: [], client: StubOmniClient.new('{}'))
      expect(ex.send(:staff_block)).to eq('(нет активных сотрудников)')
    end
  end

  describe '#call — нормализация LLM-ответа с id:N assignee' do
    let(:llm_response) do
      {
        tasks: [
          {
            assignee_username: "id:#{without_uname.id}",
            title: 'позвонить клиенту Анна',
            due_at: nil,
            priority: 'normal',
            kind: 'call',
            related_property_address: nil
          }
        ],
        uncertainties: []
      }.to_json
    end

    it 'сохраняет id:N токен в assignee_username без искажений' do
      result = described_class.new(
        transcript: 'Надежде позвонить Анне',
        staff: [without_uname],
        client: StubOmniClient.new(llm_response)
      ).call

      expect(result.error).to be_nil
      expect(result.tasks.size).to eq(1)
      expect(result.tasks.first[:assignee_username]).to eq("id:#{without_uname.id}")
    end

    it 'токен резолвится обратно в пользователя через TelegramUser.resolve_identifier' do
      result = described_class.new(
        transcript: 'Надежде позвонить Анне',
        staff: [without_uname],
        client: StubOmniClient.new(llm_response)
      ).call

      token = result.tasks.first[:assignee_username]
      expect(TelegramUser.resolve_identifier(token)).to eq(without_uname)
    end
  end
end
