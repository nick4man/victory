# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ChatTools::Staff::ListMyOpenTasks do
  let!(:with_uname) do
    TelegramUser.create!(tg_user_id: 400_001, tg_username: 'IrinLegaeva', first_name: 'Ирина',
                         status: 'active')
  end
  let!(:without_uname) do
    TelegramUser.create!(tg_user_id: 400_002, first_name: 'Надежда', last_name: 'Синицина',
                         status: 'active')
  end

  describe '.call' do
    before do
      Task.create!(title: 'позвонить', assignee_id: with_uname.id, status: 'open',
                   kind: 'call', priority: 'normal', assigned_at: Time.current,
                   due_at: 1.day.from_now)
      Task.create!(title: 'показ', assignee_id: without_uname.id, status: 'open',
                   kind: 'show', priority: 'high', assigned_at: Time.current,
                   due_at: 2.days.from_now)
    end

    it 'находит задачи по @username (case-insensitive)' do
      res = described_class.call(assignee_username: 'irinlegaeva')
      expect(res[:count]).to eq(1)
      expect(res[:tasks].first[:title]).to eq('позвонить')
      expect(res[:assignee_mention]).to eq('@IrinLegaeva')
    end

    it 'находит задачи по id:N для staff без tg_username (Iter 57)' do
      token = "id:#{without_uname.id}"
      res = described_class.call(assignee_username: token)
      expect(res[:error]).to be_nil
      expect(res[:count]).to eq(1)
      expect(res[:tasks].first[:title]).to eq('показ')
      # mention для staff без username = display_name (Надежда Синицина)
      expect(res[:assignee_mention]).to include('Надежда')
    end

    it 'возвращает user_not_found для несуществующего id:N' do
      res = described_class.call(assignee_username: 'id:999999')
      expect(res[:error]).to eq('user_not_found')
    end

    it 'возвращает user_not_found для несуществующего @username' do
      res = described_class.call(assignee_username: '@ghostuser')
      expect(res[:error]).to eq('user_not_found')
    end

    it 'фильтрует only_today' do
      Task.create!(title: 'на сегодня', assignee_id: with_uname.id, status: 'open',
                   kind: 'admin', priority: 'normal', assigned_at: Time.current,
                   due_at: Time.current.end_of_day)
      res = described_class.call(assignee_username: 'IrinLegaeva', only_today: true)
      titles = res[:tasks].map { |t| t[:title] }
      expect(titles).to include('на сегодня')
      expect(titles).not_to include('позвонить') # 1 day from now
    end
  end
end
