# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ChatTools::Staff::SearchAllTasks do
  let!(:director) do
    TelegramUser.create!(tg_user_id: 70_001, tg_username: 'dir', first_name: 'Dir',
                         role: 'director', is_manager: true, status: 'active')
  end
  let!(:agent) do
    TelegramUser.create!(tg_user_id: 70_002, tg_username: 'ag', first_name: 'Agent',
                         role: 'agent', is_manager: false, status: 'active')
  end

  before do
    Task.create!(title: 'позвонить Анне', assignee_id: agent.id, created_by_id: director.id,
                 status: 'open', kind: 'call', priority: 'high', assigned_at: Time.current,
                 due_at: 2.days.ago)
    Task.create!(title: 'показ квартиры', assignee_id: agent.id, created_by_id: director.id,
                 status: 'open', kind: 'show', priority: 'normal', assigned_at: Time.current,
                 due_at: 1.day.from_now)
    Task.create!(title: 'отчёт', assignee_id: director.id, created_by_id: agent.id,
                 status: 'done', kind: 'admin', priority: 'low', assigned_at: 1.week.ago,
                 due_at: 6.days.ago)
  end

  describe '#call' do
    context 'director' do
      it 'возвращает все задачи без фильтров (count + items)' do
        res = described_class.call({}, asked_by: director)
        expect(res[:count]).to eq(3)
        expect(res[:items].size).to eq(3)
      end

      it 'фильтрует по assignee_username' do
        res = described_class.call({ assignee_username: 'ag' }, asked_by: director)
        expect(res[:count]).to eq(2)
        expect(res[:items].map { |t| t[:assignee] }).to all(eq(agent.mention))
      end

      it 'фильтрует по status' do
        res = described_class.call({ status: 'open' }, asked_by: director)
        expect(res[:count]).to eq(2)
      end

      it 'only_overdue показывает только просроченные' do
        res = described_class.call({ only_overdue: true }, asked_by: director)
        expect(res[:count]).to eq(1)
        expect(res[:items].first[:title]).to eq('позвонить Анне')
      end

      it 'фильтрует по query (ILIKE)' do
        res = described_class.call({ query: 'показ' }, asked_by: director)
        expect(res[:count]).to eq(1)
        expect(res[:items].first[:title]).to eq('показ квартиры')
      end
    end

    context 'agent (silent self-only)' do
      it 'возвращает только свои задачи как assignee, игнорируя cross-staff фильтры' do
        res = described_class.call({ assignee_username: 'dir' }, asked_by: agent)
        expect(res[:count]).to eq(2) # agent видит только свои, не director'a
      end
    end
  end
end
