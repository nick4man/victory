# frozen_string_literal: true

require 'rails_helper'

# Нит ревью PR #221 (round 3): сквозная композиция
# LlmReplyJob → Thread.current[:lead_test_mode] → ChatTools.
# Tool-spec'и выставляют thread-local вручную; здесь проверяем, что job сам
# выставляет флаг для probe-диалога и снимает его после — в т.ч. при ошибке,
# иначе флаг протечёт в следующий job этого воркера.
RSpec.describe LlmReplyJob do
  def stub_responder(raising: false)
    captured = { flag: nil }
    responder = instance_double(Llm::ChatResponder)
    allow(responder).to receive(:call) do
      captured[:flag] = Thread.current[:lead_test_mode]
      raise 'LLM down' if raising

      { reply: 'ok', model: 'stub', escalate: false }
    end
    allow(Llm::ChatResponder).to receive(:new).and_return(responder)
    captured
  end

  it 'probe-диалог: флаг выставлен на время LLM-прогона и снят после' do
    conv = Conversation.create!(visitor_token: 'probe-qa-1', status: :active)
    captured = stub_responder

    described_class.new.perform(conv.id)

    expect(captured[:flag]).to be(true)
    expect(Thread.current[:lead_test_mode]).to be(false)
  end

  it 'боевой диалог: флаг не выставляется (регрессии нет)' do
    conv = Conversation.create!(visitor_token: 'visitor-abc', status: :active)
    captured = stub_responder

    described_class.new.perform(conv.id)

    expect(captured[:flag]).to be(false)
    expect(Thread.current[:lead_test_mode]).to be(false)
  end

  it 'флаг снимается даже при исключении в LLM-прогоне' do
    conv = Conversation.create!(visitor_token: 'probe-qa-2', status: :active)
    stub_responder(raising: true)

    expect { described_class.new.perform(conv.id) }.to raise_error('LLM down')
    expect(Thread.current[:lead_test_mode]).to be(false)
  end

  # Issue #227: auto-test по происхождению (staging/офисный IP) — контроллер
  # пометил сессию metadata['auto_test'], job обязан выставить флаг.
  it 'auto_test-сессия: флаг выставлен' do
    conv = Conversation.create!(visitor_token: 'visitor-auto', status: :active, metadata: { 'auto_test' => true })
    captured = stub_responder

    described_class.new.perform(conv.id)

    expect(captured[:flag]).to be(true)
  end

  # Issue #227: ENV-кран SITE_CHATBOT_FORCE_TEST=1 — боевой диалог тоже тестовый.
  it 'ENV-кран SITE_CHATBOT_FORCE_TEST=1: флаг выставлен для боевого диалога' do
    old = ENV.fetch('SITE_CHATBOT_FORCE_TEST', nil)
    ENV['SITE_CHATBOT_FORCE_TEST'] = '1'
    conv = Conversation.create!(visitor_token: 'visitor-force', status: :active)
    captured = stub_responder

    described_class.new.perform(conv.id)

    expect(captured[:flag]).to be(true)
  ensure
    old.nil? ? ENV.delete('SITE_CHATBOT_FORCE_TEST') : ENV['SITE_CHATBOT_FORCE_TEST'] = old
  end
end
