# frozen_string_literal: true

require 'rails_helper'

# Iter 59 — scopes для director self-audit.
# Этот spec НЕ покрывает полный Task model (legacy без coverage); только
# новые scopes из Iter 59.
RSpec.describe Task do
  let!(:director) do
    TelegramUser.create!(tg_user_id: 41_001, tg_username: 'dir', first_name: 'Director',
                         role: 'director', is_manager: true, status: 'active')
  end
  let!(:agent) do
    TelegramUser.create!(tg_user_id: 41_002, tg_username: 'ag', first_name: 'Agent',
                         role: 'agent', is_manager: false, status: 'active')
  end

  describe 'scope :created_by_tg' do
    it 'возвращает только задачи созданные данным TelegramUser' do
      t1 = described_class.create!(title: 'A', assignee_id: agent.id, created_by_id: director.id,
                                   status: 'open', kind: 'call', priority: 'normal', assigned_at: Time.current)
      _t2 = described_class.create!(title: 'B', assignee_id: agent.id, created_by_id: agent.id,
                                    status: 'open', kind: 'call', priority: 'normal', assigned_at: Time.current)
      expect(described_class.created_by_tg(director).pluck(:id)).to eq([t1.id])
    end
  end

  describe 'scope :created_in' do
    it 'фильтрует по диапазону created_at' do
      t = described_class.create!(title: 'X', assignee_id: agent.id, created_by_id: director.id,
                                  status: 'open', kind: 'call', priority: 'normal', assigned_at: Time.current)
      expect(described_class.created_in(Time.current.beginning_of_day..Time.current.end_of_day)).to include(t)
      expect(described_class.created_in(2.days.ago.beginning_of_day..1.day.ago.end_of_day)).not_to include(t)
    end
  end
end
