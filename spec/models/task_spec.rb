# frozen_string_literal: true

require 'rails_helper'

# Iter 59/60 — scopes для director self-audit + attachments helper.
# Этот spec НЕ покрывает полный Task model (legacy без coverage); только
# новые методы из Iter 59-60.
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

  describe '#append_attachment!' do
    let(:task) do
      described_class.create!(title: 'Task with file', assignee_id: agent.id, created_by_id: director.id,
                              status: 'open', kind: 'document', priority: 'normal', assigned_at: Time.current)
    end

    it 'добавляет запись в attachments jsonb' do
      task.append_attachment!(tg_file_id: 'F1', nc_url: 'https://nc/s/abc', kind: 'image', uploaded_by: director.id)
      task.reload
      expect(task.attachments.size).to eq(1)
      expect(task.attachments.first['tg_file_id']).to eq('F1')
      expect(task.attachments.first['nc_url']).to eq('https://nc/s/abc')
      expect(task.attachments.first['kind']).to eq('image')
      expect(task.attachments.first['uploaded_by']).to eq(director.id)
      expect(task.attachments.first['uploaded_at']).to be_present
    end

    it 'cap at last 20 entries (anti-bloat)' do
      25.times { |i| task.append_attachment!(tg_file_id: "F#{i}", nc_url: "url#{i}") }
      expect(task.reload.attachments.size).to eq(20)
      expect(task.attachments.first['tg_file_id']).to eq('F5') # последние 20 = F5..F24
    end
  end
end
