# frozen_string_literal: true

require 'rails_helper'

# Нит ревью PR #221 (round 3): сквозная композиция
# LlmReplyJob → Thread.current[:lead_test_mode] → ChatTools.
# Tool-spec'и выставляют thread-local вручную; здесь проверяем, что job сам
# выставляет флаг для probe-диалога и снимает его после — в т.ч. при ошибке,
# иначе флаг протечёт в следующий job этого воркера.
RSpec.describe LlmReplyJob do
  def stub_responder(raising: false)
    captured = { flag: nil, ip: nil, user_agent: nil }
    responder = instance_double(Llm::ChatResponder)
    allow(responder).to receive(:call) do
      captured[:flag] = Thread.current[:lead_test_mode]
      captured[:ip] = Thread.current[:lead_client_ip]
      captured[:user_agent] = Thread.current[:lead_client_user_agent]
      raise 'LLM down' if raising

      { reply: 'ok', model: 'stub', escalate: false }
    end
    allow(Llm::ChatResponder).to receive(:new).and_return(responder)
    captured
  end

  it 'probe-диалог: флаг выставлен на время LLM-прогона и снят после' do
    conv = Conversation.create!(visitor_token: SecureRandom.hex(16), status: :active,
                                metadata: { 'test_probe' => true })
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
    conv = Conversation.create!(visitor_token: SecureRandom.hex(16), status: :active,
                                metadata: { 'test_probe' => true })
    stub_responder(raising: true)

    expect { described_class.new.perform(conv.id) }.to raise_error('LLM down')
    expect(Thread.current[:lead_test_mode]).to be(false)
  end

  # Issue #275: IP/UA посетителя едут на карточку лида. MessagesController
  # пишет их в metadata user-сообщения, job выставляет thread-local для
  # чатовых тулзов и снимает после — иначе значения протекли бы в чужой job.
  it 'IP/UA из metadata триггерного сообщения доступны тулзам и снимаются после' do
    conv = Conversation.create!(visitor_token: 'visitor-ip', status: :active)
    msg = conv.chat_messages.create!(role: :user, body: 'оцените квартиру',
                                     metadata: { 'ip' => '203.0.113.10', 'user_agent' => 'Mozilla/5.0 Chat' })
    captured = stub_responder

    described_class.new.perform(conv.id, msg.id)

    expect(captured[:ip]).to eq('203.0.113.10')
    expect(captured[:user_agent]).to eq('Mozilla/5.0 Chat')
    expect(Thread.current[:lead_client_ip]).to be_nil
    expect(Thread.current[:lead_client_user_agent]).to be_nil
  end

  it 'сообщение без IP/UA в metadata — thread-local пустые (регрессии нет)' do
    conv = Conversation.create!(visitor_token: 'visitor-noip', status: :active)
    msg = conv.chat_messages.create!(role: :user, body: 'привет')
    captured = stub_responder

    described_class.new.perform(conv.id, msg.id)

    expect(captured[:ip]).to be_nil
    expect(captured[:user_agent]).to be_nil
  end

  it 'IP/UA снимаются даже при исключении в LLM-прогоне' do
    conv = Conversation.create!(visitor_token: 'visitor-ip-err', status: :active)
    msg = conv.chat_messages.create!(role: :user, body: 'оцените',
                                     metadata: { 'ip' => '203.0.113.10' })
    stub_responder(raising: true)

    expect { described_class.new.perform(conv.id, msg.id) }.to raise_error('LLM down')
    expect(Thread.current[:lead_client_ip]).to be_nil
    expect(Thread.current[:lead_client_user_agent]).to be_nil
  end
end
