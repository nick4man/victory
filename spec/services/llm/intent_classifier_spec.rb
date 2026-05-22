# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::IntentClassifier do
  # Stub OmniClient — возвращает заранее заданный JSON-content.
  class StubOmniForIntent # rubocop:disable Lint/ConstantDefinitionInBlock
    def initialize(content: nil, raise: nil)
      @content = content
      @raise = raise
    end

    def complete(_messages, **_opts)
      raise @raise if @raise

      { content: @content, model: 'stub-model' }
    end
  end

  describe 'Result struct' do
    it '#success? true когда error nil' do
      r = described_class::Result.new(intent: 'inquiry', confidence: 0.9)
      expect(r.success?).to be(true)
    end

    it '#actionable? true для inquiry/question/appointment' do
      %w[inquiry question appointment].each do |i|
        expect(described_class::Result.new(intent: i).actionable?).to be(true)
      end
      %w[spam abuse test unclear complaint].each do |i|
        expect(described_class::Result.new(intent: i).actionable?).to be(false)
      end
    end

    it '#droppable? true для spam/abuse' do
      expect(described_class::Result.new(intent: 'spam').droppable?).to be(true)
      expect(described_class::Result.new(intent: 'abuse').droppable?).to be(true)
      expect(described_class::Result.new(intent: 'inquiry').droppable?).to be(false)
    end
  end

  describe '.call' do
    context 'happy path — каждый из 8 intents' do
      Llm::IntentClassifier::INTENTS.each do |intent|
        it "распознаёт #{intent}" do
          client = StubOmniForIntent.new(content: { intent: intent, confidence: 0.85, reasoning: 'stub' }.to_json)
          r = described_class.call(text: 'тест', client: client)
          expect(r.intent).to eq(intent)
          expect(r.confidence).to eq(0.85)
          expect(r.error).to be_nil
        end
      end
    end

    context 'edge: пустой text' do
      it 'без LLM-вызова → unclear + error' do
        client = StubOmniForIntent.new
        expect(client).not_to receive(:complete)
        r = described_class.call(text: '   ', client: client)
        expect(r.intent).to eq('unclear')
        expect(r.confidence).to eq(0.0)
        expect(r.error).to eq('empty input')
      end
    end

    context 'edge: unknown intent от LLM' do
      it 'normalize в unclear (защита от model hallucination)' do
        client = StubOmniForIntent.new(content: { intent: 'flirty', confidence: 0.99 }.to_json)
        r = described_class.call(text: 'привет', client: client)
        expect(r.intent).to eq('unclear')
      end
    end

    context 'edge: malformed JSON' do
      it 'возвращает unclear (parse_response → {} → intent nil → unclear)' do
        client = StubOmniForIntent.new(content: 'not json at all')
        r = described_class.call(text: 'тест', client: client)
        expect(r.intent).to eq('unclear')
        expect(r.confidence).to eq(0.0)
      end
    end

    context 'edge: confidence outside [0,1]' do
      it 'клампит в диапазон' do
        client = StubOmniForIntent.new(content: { intent: 'inquiry', confidence: 5.5 }.to_json)
        r = described_class.call(text: 'квартира', client: client)
        expect(r.confidence).to eq(1.0)

        client2 = StubOmniForIntent.new(content: { intent: 'inquiry', confidence: -3 }.to_json)
        r2 = described_class.call(text: 'квартира', client: client2)
        expect(r2.confidence).to eq(0.0)
      end
    end

    context 'edge: LLM exception' do
      it 'fallback на unclear + error message' do
        client = StubOmniForIntent.new(raise: StandardError.new('LLM connection refused'))
        r = described_class.call(text: 'тест', client: client)
        expect(r.intent).to eq('unclear')
        expect(r.error).to include('LLM connection refused')
      end
    end

    context 'reasoning truncation' do
      it 'ограничено 200 chars' do
        long = 'x' * 500
        client = StubOmniForIntent.new(content: { intent: 'spam', confidence: 0.9, reasoning: long }.to_json)
        r = described_class.call(text: 'купи биток', client: client)
        expect(r.reasoning.size).to be <= 200
      end
    end
  end
end
