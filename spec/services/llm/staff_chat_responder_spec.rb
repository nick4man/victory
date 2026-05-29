# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::StaffChatResponder do
  let!(:asker) do
    TelegramUser.create!(tg_user_id: 300_001, tg_username: 'irina', first_name: 'Ирина',
                         role: 'agent', is_manager: false, status: 'active', dm_chat_id: 300_001)
  end
  let!(:director) do
    TelegramUser.create!(tg_user_id: 300_002, tg_username: 'oks', first_name: 'Оксана',
                         role: 'director', is_manager: true, status: 'active', dm_chat_id: 300_002)
  end

  let(:tg_client) { instance_double(::Telegram::Client, send_message: { 'message_id' => 1 }) }
  let(:llm_client) { instance_double(::Llm::OmniClient) }

  # Helper для stub'а QuestionClassifier
  def stub_classifier(kind:, confidence: 0.9, model: 'stub-model')
    result = ::Llm::QuestionClassifier::Result.new(
      kind: kind, confidence: confidence, reasoning: 'stub', model: model, error: nil
    )
    allow(::Llm::QuestionClassifier).to receive(:call).and_return(result)
  end

  describe '#call' do
    context 'empty question' do
      it 'возвращает Result с error «пустой вопрос»' do
        result = described_class.call(question: '   ', asked_by: asker, msg: {})
        expect(result.error).to include('пустой вопрос')
        expect(result.success?).to be(false)
      end
    end

    context 'escalation path (kind=escalation)' do
      before { stub_classifier(kind: 'escalation') }

      it 'отправляет DM director\'у + возвращает escalation answer' do
        result = described_class.call(
          question: 'это очень сложный кейс — мне нужна помощь',
          asked_by: asker,
          msg: { 'message_id' => 99 },
          client: llm_client,
          tg_client: tg_client
        )

        expect(result.kind).to eq('escalation')
        expect(result.answer).to include('🚨')
        expect(result.success?).to be(true)
        expect(tg_client).to have_received(:send_message).with(
          a_string_matching(/Эскалация/), hash_including(chat_id: director.dm_chat_id)
        )
      end

      it 'persisted StaffQuestion с kind=escalation' do
        expect {
          described_class.call(question: 'кейс', asked_by: asker, msg: {}, client: llm_client, tg_client: tg_client)
        }.to change { StaffQuestion.count }.by(1)
        sq = StaffQuestion.order(:id).last
        expect(sq.kind).to eq('escalation')
        expect(sq.asked_by_id).to eq(asker.id)
      end
    end

    context 'tool-use path (kind=clarification, LLM returns final content без tool_calls)' do
      before do
        stub_classifier(kind: 'clarification')
        allow(llm_client).to receive(:complete).and_return(
          { content: 'Прямой ответ от LLM без tool-вызовов.', tool_calls: nil, model: 'stub' }
        )
      end

      it 'возвращает финальный content из LLM' do
        result = described_class.call(
          question: 'как работает /assign?',
          asked_by: asker, msg: {},
          client: llm_client, tg_client: tg_client
        )
        expect(result.success?).to be(true)
        expect(result.kind).to eq('clarification')
        expect(result.answer).to eq('Прямой ответ от LLM без tool-вызовов.')
        expect(result.used_tools).to eq([])
      end
    end

    context 'tool-use loop (LLM делает tool_call → tool result → final answer)' do
      before do
        stub_classifier(kind: 'information')
        # 1-я итерация — tool_call
        # 2-я итерация — final content
        @call_count = 0
        allow(llm_client).to receive(:complete) do
          @call_count += 1
          if @call_count == 1
            {
              content: nil,
              tool_calls: [{
                id: 'tc_1',
                name: 'list_my_open_tasks',
                arguments: { assignee_username: asker.tg_username }
              }],
              model: 'stub'
            }
          else
            { content: 'У тебя 3 открытых задачи.', tool_calls: nil, model: 'stub' }
          end
        end

        # Stub Registry.call для tool execution
        allow(::ChatTools::Staff::Registry).to receive(:call).and_return({ count: 3, tasks: [] })
      end

      it 'выполняет tool + возвращает финальный answer + used_tools' do
        result = described_class.call(
          question: 'мои задачи?',
          asked_by: asker, msg: {},
          client: llm_client, tg_client: tg_client
        )
        expect(result.answer).to eq('У тебя 3 открытых задачи.')
        expect(result.used_tools).to eq(['list_my_open_tasks'])
        expect(::ChatTools::Staff::Registry).to have_received(:call).with(
          'list_my_open_tasks', hash_including(:assignee_username), asked_by: asker
        )
      end
    end

    context 'MAX_TOOL_ITERATIONS cap (LLM зависает в tool-loop)' do
      before do
        stub_classifier(kind: 'information')
        # LLM каждый раз возвращает tool_call — никогда не даёт final content
        allow(llm_client).to receive(:complete).and_return({
          content: nil,
          tool_calls: [{ id: 't', name: 'list_my_open_tasks', arguments: {} }],
          model: 'stub'
        })
        allow(::ChatTools::Staff::Registry).to receive(:call).and_return({})
      end

      it 'упирается в cap и возвращает fallback message' do
        result = described_class.call(
          question: 'мои задачи?',
          asked_by: asker, msg: {},
          client: llm_client, tg_client: tg_client
        )
        expect(result.answer).to include('модель не дала финальный ответ')
        # MAX_TOOL_ITERATIONS = 4 — должно быть 4 завала
        expect(llm_client).to have_received(:complete).exactly(4).times
      end
    end

    context 'LLM exception' do
      before do
        stub_classifier(kind: 'information')
        allow(llm_client).to receive(:complete).and_raise(::Llm::OmniClient::Error.new('all models failed'))
      end

      it 'возвращает empty_result с error message' do
        result = described_class.call(
          question: 'тест', asked_by: asker, msg: {},
          client: llm_client, tg_client: tg_client
        )
        expect(result.success?).to be(false)
        expect(result.error).to include('all models failed')
        expect(result.answer).to include('Не удалось')
      end
    end

    context 'BotCommandLog audit-trail' do
      before do
        stub_classifier(kind: 'information')
        allow(llm_client).to receive(:complete).and_return({ content: 'OK', tool_calls: nil, model: 'stub' })
      end

      it 'создаёт row в BotCommandLog с command=qna + result=kind' do
        expect {
          described_class.call(question: 'OK?', asked_by: asker, msg: {}, client: llm_client, tg_client: tg_client)
        }.to change { BotCommandLog.count }.by(1)
        log = BotCommandLog.order(:id).last
        expect(log.command).to eq('qna')
        expect(log.result).to eq('information')
        expect(log.tg_user_id).to eq(asker.tg_user_id)
      end
    end
  end
end
