# frozen_string_literal: true

require 'rails_helper'

RSpec.describe StaffMetric do
  let(:staff) { TelegramUser.create!(tg_user_id: 5_001, status: 'active', role: 'agent') }

  def build_metric(attrs = {})
    described_class.new({
      staff: staff,
      date: Date.current,
      tasks_assigned: 0, tasks_completed: 0, tasks_on_time: 0,
      tasks_overdue: 0, avg_completion_time_sec: 0,
      questions_asked: 0, leads_assigned: 0,
      leads_first_contact_in_30m: 0, leads_converted: 0,
      suspicious_completions: 0, documents_uploaded: 0
    }.merge(attrs))
  end

  describe 'validations' do
    it 'требует date' do
      m = build_metric(date: nil)
      expect(m).not_to be_valid
      expect(m.errors[:date]).to be_present
    end

    it 'requires unique (staff_id, date)' do
      build_metric.save!
      dup = build_metric
      expect(dup).not_to be_valid
      expect(dup.errors[:staff_id]).to be_present
    end

    it 'allows same date for different staff' do
      build_metric.save!
      other = TelegramUser.create!(tg_user_id: 5_002, status: 'active', role: 'agent')
      m = described_class.new(staff: other, date: Date.current, tasks_assigned: 0,
                              tasks_completed: 0, tasks_on_time: 0)
      expect(m).to be_valid
    end
  end

  describe 'scopes' do
    let!(:today)  { build_metric.tap(&:save!) }
    let!(:past)   { build_metric(date: 7.days.ago.to_date).tap(&:save!) }
    let!(:future) { build_metric(date: 7.days.from_now.to_date).tap(&:save!) }

    it 'for_date filters by exact date' do
      expect(described_class.for_date(Date.current)).to contain_exactly(today)
    end

    it 'for_period filters by range' do
      range = 3.days.ago.to_date..3.days.from_now.to_date
      expect(described_class.for_period(range)).to contain_exactly(today)
    end

    it 'for_staff filters by TelegramUser' do
      other = TelegramUser.create!(tg_user_id: 5_003, status: 'active', role: 'agent')
      foreign = described_class.create!(staff: other, date: Date.current,
                                        tasks_assigned: 0, tasks_completed: 0,
                                        tasks_on_time: 0)
      expect(described_class.for_staff(staff)).to include(today)
      expect(described_class.for_staff(staff)).not_to include(foreign)
    end
  end

  describe 'derived rates' do
    it 'completion_rate = 0 when tasks_assigned zero' do
      expect(build_metric.completion_rate).to eq(0.0)
    end

    it 'completion_rate divides done/assigned' do
      m = build_metric(tasks_assigned: 10, tasks_completed: 7)
      expect(m.completion_rate).to be_within(0.001).of(0.7)
    end

    it 'on_time_rate = 0 when tasks_completed zero' do
      expect(build_metric(tasks_completed: 0).on_time_rate).to eq(0.0)
    end

    it 'on_time_rate divides on_time/completed' do
      m = build_metric(tasks_completed: 4, tasks_on_time: 3)
      expect(m.on_time_rate).to be_within(0.001).of(0.75)
    end

    it 'question_dependency divides questions_asked / tasks_completed' do
      m = build_metric(tasks_completed: 5, questions_asked: 2)
      expect(m.question_dependency).to be_within(0.001).of(0.4)
    end

    it 'first_contact_30m_rate divides fc30/leads_assigned' do
      m = build_metric(leads_assigned: 10, leads_first_contact_in_30m: 4)
      expect(m.first_contact_30m_rate).to be_within(0.001).of(0.4)
    end

    it 'lead_conversion_rate_local guards zero denominator' do
      expect(build_metric(leads_assigned: 0).lead_conversion_rate_local).to eq(0.0)
    end
  end
end
