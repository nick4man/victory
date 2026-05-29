# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ChatTools::Staff::SummarizeGroupMessages do
  let!(:director) do
    TelegramUser.create!(tg_user_id: 600_001, tg_username: 'oks', first_name: 'Оксана',
                         role: 'director', is_manager: true, status: 'active')
  end
  let!(:agent) do
    TelegramUser.create!(tg_user_id: 600_002, tg_username: 'irina', first_name: 'Ирина',
                         role: 'agent', is_manager: false, status: 'active')
  end

  let(:base_msg) do
    {
      tg_chat_id: -1_003_779_115_845, tg_thread_id: 17,
      tg_user_id: director.tg_user_id, sender_username: director.tg_username,
      sender_first_name: 'Оксана', payload_kind: 'text', has_attachment: false
    }
  end

  before do
    # Stub OmniClient — LLM не запускается реально
    stub_const('FakeLlmForSummary', Class.new do
      def complete(_messages, **_opts)
        {
          content: "📌 **Темы**\n• Обсуждение квартиры в Канищево\n\n✅ **Решения**\n• Назначен показ на пятницу",
          model: 'stub-model'
        }
      end
    end)
    allow(::Llm::OmniClient).to receive(:new).and_return(FakeLlmForSummary.new)
  end

  describe '.call' do
    context 'director с достаточным количеством messages' do
      before do
        5.times do |i|
          TelegramGroupMessage.create!(base_msg.merge(
            tg_message_id: 100 + i,
            body: "Сообщение про Канищево #{i}",
            sent_at: 2.hours.ago + i.minutes
          ))
        end
      end

      it 'возвращает summary с count + period_label' do
        res = described_class.call({ period: 'today' }, asked_by: director)
        expect(res[:count]).to eq(5)
        expect(res[:period_label]).to eq('сегодня')
        expect(res[:summary]).to include('📌')
        expect(res[:summary]).to include('Темы')
        expect(res[:model]).to eq('stub-model')
        expect(res[:source_ids].size).to eq(5)
      end

      it 'фильтрует по sender_username' do
        # Добавим msg от другого user
        TelegramGroupMessage.create!(base_msg.merge(
          tg_message_id: 200, sender_username: 'masha', tg_user_id: 999,
          body: 'не Оксанино сообщение', sent_at: 1.hour.ago
        ))
        res = described_class.call({ period: 'today', sender_username: 'masha' }, asked_by: director)
        expect(res[:count]).to eq(1)
      end

      it 'фильтрует по query (FTS pre-filter)' do
        # Добавим msg которое не содержит «Канищево»
        TelegramGroupMessage.create!(base_msg.merge(
          tg_message_id: 300, body: 'другая тема', sent_at: 1.hour.ago
        ))
        res = described_class.call({ query: 'Канищево', period: 'today' }, asked_by: director)
        expect(res[:count]).to eq(5) # все 5 Канищево match'нулись
      end
    end

    context 'недостаточно messages (< MIN_SOURCES = 3)' do
      before do
        2.times do |i|
          TelegramGroupMessage.create!(base_msg.merge(
            tg_message_id: 400 + i, body: "msg #{i}", sent_at: 30.minutes.ago + i.minutes
          ))
        end
      end

      it 'не запускает LLM, возвращает note' do
        expect_any_instance_of(FakeLlmForSummary).not_to receive(:complete)
        res = described_class.call({ period: 'today' }, asked_by: director)
        expect(res[:count]).to eq(2)
        expect(res[:summary]).to be_nil
        expect(res[:note]).to include('Недостаточно сообщений')
      end
    end

    context 'agent (silent denied)' do
      it 'возвращает denied без LLM-call' do
        expect_any_instance_of(FakeLlmForSummary).not_to receive(:complete)
        res = described_class.call({ period: 'today' }, asked_by: agent)
        expect(res[:count]).to eq(0)
        expect(res[:denied]).to include('manager+ only')
      end
    end

    context 'без asked_by' do
      it 'caller_unknown' do
        res = described_class.call({ period: 'today' })
        expect(res[:error]).to eq('caller_unknown')
      end
    end

    context 'LLM exception' do
      before do
        4.times do |i|
          TelegramGroupMessage.create!(base_msg.merge(
            tg_message_id: 500 + i, body: "msg #{i}", sent_at: 1.hour.ago + i.minutes
          ))
        end
        allow_any_instance_of(FakeLlmForSummary).to receive(:complete).and_raise(StandardError.new('LLM down'))
      end

      it 'возвращает tool_failed без crash' do
        res = described_class.call({ period: 'today' }, asked_by: director)
        expect(res[:error]).to eq('tool_failed')
        expect(res[:message]).to include('LLM down')
      end
    end
  end
end
