# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::VoiceIntentBranch do
  # Минимальный стаб OmniClient — возвращает заранее заданный JSON content.
  class StubOmniClientForBranch # rubocop:disable Lint/ConstantDefinitionInBlock
    def initialize(content: nil, raise: nil)
      @content = content
      @raise   = raise
    end

    def complete(_messages, **_opts)
      raise @raise if @raise

      { content: @content, model: 'stub' }
    end
  end

  describe '.call' do
    it 'возвращает :query когда LLM kind=query и confidence>=0.7' do
      client = StubOmniClientForBranch.new(content: { kind: 'query', confidence: 0.9 }.to_json)
      expect(described_class.call('какие задания я давала сегодня', client: client)).to eq(:query)
    end

    it 'возвращает :task_batch когда LLM kind=task_batch с любой confidence' do
      client = StubOmniClientForBranch.new(content: { kind: 'task_batch', confidence: 0.95 }.to_json)
      expect(described_class.call('Ирине позвонить Анне', client: client)).to eq(:task_batch)
    end

    it 'фоллбэк на :task_batch при low-confidence query (< 0.7) — safer default' do
      client = StubOmniClientForBranch.new(content: { kind: 'query', confidence: 0.5 }.to_json)
      expect(described_class.call('расскажи что-нибудь', client: client)).to eq(:task_batch)
    end

    it 'фоллбэк на :task_batch при LLM exception' do
      client = StubOmniClientForBranch.new(raise: StandardError.new('LLM down'))
      expect(described_class.call('какие лиды я направила', client: client)).to eq(:task_batch)
    end

    it 'фоллбэк на :task_batch при malformed JSON в content' do
      client = StubOmniClientForBranch.new(content: 'не JSON')
      expect(described_class.call('какие задания', client: client)).to eq(:task_batch)
    end

    it 'пустой транскрипт → :task_batch без LLM-call (early return)' do
      client = StubOmniClientForBranch.new
      expect(client).not_to receive(:complete)
      expect(described_class.call('   ', client: client)).to eq(:task_batch)
    end

    it 'неизвестный kind в JSON → :task_batch' do
      client = StubOmniClientForBranch.new(content: { kind: 'unknown', confidence: 0.99 }.to_json)
      expect(described_class.call('тест', client: client)).to eq(:task_batch)
    end
  end
end
