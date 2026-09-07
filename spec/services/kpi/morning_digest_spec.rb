# frozen_string_literal: true

require 'rails_helper'

# Phase 6 — Per-staff text builder. Pure logic — generates HTML-formatted
# digest. No side-effects (DM dispatch — отдельный job). Тестируем block
# structure + section content + edge cases (empty data, single records).
RSpec.describe Kpi::MorningDigest do
  let(:staff) do
    TelegramUser.create!(tg_user_id: 8_001, status: 'active', role: 'agent',
                         first_name: 'Анна', tg_username: 'anna_test')
  end

  # Tuesday 09:00 MSK — guarantees not weekend
  let(:weekday_morning) { Time.zone.local(2026, 5, 19, 9, 0, 0) }

  describe '#greeting' do
    it 'includes staff first_name' do
      digest = described_class.new(staff: staff, now: weekday_morning)
      expect(digest.greeting).to include('Анна')
      expect(digest.greeting).to include('С добрым утром')
    end

    it 'falls back to tg_username when first_name blank' do
      staff.update!(first_name: nil)
      digest = described_class.new(staff: staff, now: weekday_morning)
      expect(digest.greeting).to include('anna_test')
    end

    it 'fallback to "коллега" when no name/username' do
      staff.update!(first_name: nil, tg_username: nil)
      digest = described_class.new(staff: staff, now: weekday_morning)
      expect(digest.greeting).to include('коллега')
    end
  end

  describe '#build_text — empty state' do
    it 'shows no-tasks placeholder when nothing pending' do
      text = described_class.new(staff: staff, now: weekday_morning).build_text
      expect(text).to include('На сегодня задач нет')
    end

    it 'shows no-leads placeholder when no open leads' do
      text = described_class.new(staff: staff, now: weekday_morning).build_text
      expect(text).to include('Активных лидов нет')
    end

    it 'omits overdue_block when no overdue tasks' do
      text = described_class.new(staff: staff, now: weekday_morning).build_text
      expect(text).not_to include('Просрочки')
    end

    it 'omits sla_warnings_block when no warnings' do
      text = described_class.new(staff: staff, now: weekday_morning).build_text
      expect(text).not_to include('SLA-warnings')
    end
  end

  describe '#build_text — with overdue tasks' do
    before do
      # Фикстуры привязаны к weekday_morning, а не к реальному «сейчас»:
      # дайджест фильтрует по переданному now, поэтому due_at: 1.day.ago
      # (реальное время) переставал попадать в выборку по мере того, как
      # настоящая дата уходила от зафиксированной в спеке.
      Task.create!(
        assignee_id: staff.id, title: 'Просроченная задача',
        status: 'open', due_at: weekday_morning - 1.day, kind: 'call', priority: 'normal'
      )
    end

    it 'includes overdue block' do
      text = described_class.new(staff: staff, now: weekday_morning).build_text
      expect(text).to include('Просрочки')
      expect(text).to include('Просроченная задача')
    end

    it 'shows /done command hint' do
      text = described_class.new(staff: staff, now: weekday_morning).build_text
      expect(text).to include('/done')
    end
  end

  describe '#build_text — with leads' do
    before do
      buyer_order = BuyerOrder.create!(crm_id: 900_905, client_name: 'Test', deal_type: 'sale',
                                       deal_state: 'lead', synced_at: Time.current)
      LeadEvent.create!(
        lead_ref: buyer_order, source: 'site_form',
        tg_chat_id: -1_003_779_115_845, anchor_topic_key: 'apartments',
        current_stage: 'new', assigned_to: staff, assigned_at: 1.hour.ago,
        metadata: { 'name' => 'Test Client' }
      )
    end

    it 'shows open leads count' do
      text = described_class.new(staff: staff, now: weekday_morning).build_text
      expect(text).to include('Активных лидов: 1')
    end
  end

  describe '#build_text — SLA warnings' do
    before do
      buyer_order = BuyerOrder.create!(crm_id: 900_906, client_name: 'SLA', deal_type: 'sale',
                                       deal_state: 'lead', synced_at: Time.current)
      # Assigned 31 minutes ago, no first_contact_at → SLA warning
      LeadEvent.create!(
        lead_ref: buyer_order, source: 'site_form',
        tg_chat_id: -1_003_779_115_845, anchor_topic_key: 'apartments',
        current_stage: 'new', assigned_to: staff, assigned_at: weekday_morning - 31.minutes,
        metadata: { 'name' => 'SLA Client' }
      )
    end

    it 'shows SLA warnings block' do
      text = described_class.new(staff: staff, now: weekday_morning).build_text
      expect(text).to include('SLA-warnings')
      expect(text).to include('SLA Client')
    end
  end

  describe '#yesterday_recap' do
    it 'shows placeholder when no StaffMetric' do
      result = described_class.new(staff: staff, now: weekday_morning).yesterday_recap
      expect(result).to include('данных пока нет')
    end

    it 'includes done/assigned counts when StaffMetric exists' do
      StaffMetric.create!(staff: staff, date: (weekday_morning - 1.day).to_date,
                          tasks_assigned: 5, tasks_completed: 4, tasks_on_time: 3)
      result = described_class.new(staff: staff, now: weekday_morning).yesterday_recap
      expect(result).to include('4/5')
      expect(result).to include('75%') # on-time rate
    end
  end

  describe 'visual helpers' do
    let(:digest) { described_class.new(staff: staff, now: weekday_morning) }

    it 'kind_emoji maps known kinds' do
      expect(digest.kind_emoji('call')).to eq('📞')
      expect(digest.kind_emoji('show')).to eq('🏠')
      expect(digest.kind_emoji('document')).to eq('📄')
    end

    it 'kind_emoji returns default emoji для unknown kind' do
      expect(digest.kind_emoji('unknown')).to eq('📌')
    end

    it 'stage_emoji maps known stages' do
      expect(digest.stage_emoji('new')).to eq('🆕')
      expect(digest.stage_emoji('first_contact')).to eq('📞')
      expect(digest.stage_emoji('closed_won')).to eq('✅')
      expect(digest.stage_emoji('closed_lost')).to eq('❌')
    end
  end
end
