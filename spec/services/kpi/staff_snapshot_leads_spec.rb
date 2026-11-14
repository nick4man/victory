# frozen_string_literal: true

require 'rails_helper'

# Тестовые лиды песочницы (staff_test: true) не должны утекать в персистентные
# KPI — StaffMetric считается ежедневно и хранится годами, в отличие от
# карточек CRM (Checker.sandbox_lead?), которые видно только в тестовом боте.
RSpec.describe Kpi::StaffSnapshot do
  let!(:staff) do
    TelegramUser.create!(tg_user_id: 96_001, status: 'active', role: 'agent',
                         first_name: 'Игорь', tg_username: 'igor', dm_chat_id: 96_001)
  end
  let(:date) { Date.parse('2026-09-17') }

  def snapshot_metric
    described_class.run!(date: date)
    StaffMetric.find_by(staff: staff, date: date)
  end

  it 'тестовый лид не считается в leads_assigned/leads_first_contact_in_30m; реальный — считается' do
    now = date.all_day.begin + 2.hours
    LeadEvent.create!(lead_ref: staff, source: 'manual', current_stage: 'first_contact',
                      anchor_topic_key: 'dispatcher', tg_chat_id: staff.tg_user_id,
                      assigned_to: staff, assigned_at: now, first_contact_at: now, staff_test: true,
                      metadata: { 'name' => 'Тест Тестович', 'sandbox' => true })
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_2,
                      assigned_to: staff, assigned_at: now, first_contact_at: now,
                      metadata: { 'name' => 'Анна Реальная' })

    metric = snapshot_metric

    expect(metric.leads_assigned).to eq(1)
    expect(metric.leads_first_contact_in_30m).to eq(1)
  end
end
