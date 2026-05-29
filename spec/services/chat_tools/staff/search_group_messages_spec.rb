# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ChatTools::Staff::SearchGroupMessages do
  let!(:director) do
    TelegramUser.create!(tg_user_id: 60_001, tg_username: 'oks', first_name: 'Оксана',
                         role: 'director', is_manager: true, status: 'active')
  end
  let!(:agent) do
    TelegramUser.create!(tg_user_id: 60_002, tg_username: 'irina', first_name: 'Ирина',
                         role: 'agent', is_manager: false, status: 'active')
  end

  let(:base_msg) do
    {
      tg_chat_id: -1_003_779_115_845, tg_thread_id: 17,
      tg_user_id: agent.tg_user_id, sender_username: agent.tg_username,
      sender_first_name: 'Ирина', payload_kind: 'text', has_attachment: false
    }
  end

  before do
    TelegramGroupMessage.create!(base_msg.merge(tg_message_id: 1, body: 'Канищево квартира 3-комн 8.5 млн', sent_at: 2.hours.ago))
    TelegramGroupMessage.create!(base_msg.merge(tg_message_id: 2, body: 'Солотча дом 12 млн срочно', sent_at: 1.day.ago))
    TelegramGroupMessage.create!(base_msg.merge(tg_message_id: 3, body: 'Звонок клиенту по Канищево', sent_at: 5.days.ago, sender_username: 'masha', tg_user_id: 60_003))
  end

  describe '#call' do
    context 'director (manager+)' do
      it 'находит сообщения по query' do
        res = described_class.call({ query: 'Канищево' }, asked_by: director)
        expect(res[:count]).to eq(2)
        expect(res[:items].map { |i| i[:body_excerpt] }.join(' ')).to include('Канищево')
      end

      it 'фильтрует по sender_username' do
        res = described_class.call({ query: 'Канищево', sender_username: 'masha' }, asked_by: director)
        expect(res[:count]).to eq(1)
        expect(res[:items].first[:sender]).to eq('@masha')
      end

      it 'фильтрует по period=today (включает только последние)' do
        res = described_class.call({ query: 'Канищево', period: 'today' }, asked_by: director)
        expect(res[:count]).to eq(1) # только 2-hours-ago, не 5-days-ago
        expect(res[:period_label]).to eq('сегодня')
      end

      it 'возвращает tg_link для click-to-jump' do
        res = described_class.call({ query: 'Солотча' }, asked_by: director)
        expect(res[:items].first[:tg_link]).to include('https://t.me/c/')
      end
    end

    context 'agent (silent denied)' do
      it 'возвращает denied + count=0' do
        res = described_class.call({ query: 'Канищево' }, asked_by: agent)
        expect(res[:count]).to eq(0)
        expect(res[:denied]).to include('manager+')
      end
    end

    context 'edge: пустой query' do
      it 'возвращает error: empty_query' do
        res = described_class.call({ query: '' }, asked_by: director)
        expect(res[:error]).to eq('empty_query')
      end
    end

    context 'без asked_by' do
      it 'caller_unknown' do
        res = described_class.call({ query: 'тест' })
        expect(res[:error]).to eq('caller_unknown')
      end
    end
  end
end
