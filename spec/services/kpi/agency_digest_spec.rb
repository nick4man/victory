# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Kpi::AgencyDigest do
  let(:lead_ref) do
    User.find_or_create_by!(email: "stub-#{SecureRandom.hex(4)}@victory.ru") do |u|
      u.password = SecureRandom.urlsafe_base64(20)
      u.first_name = 'Test'; u.last_name = 'Stub'; u.role = :client; u.active = true
    end
  end

  # Issue #214 (ревью PR #221, round 3): probe-прогон чат-бота
  # (staff_test=true) не должен попадать в pipeline-метрики агентства.
  describe '#build_text' do
    it 'pipeline не считает probe/staff_test-лиды, боевые считает' do
      LeadEvent.create!(
        lead_ref: lead_ref, source: 'site_form', current_stage: 'new',
        anchor_topic_key: 'dispatcher', tg_chat_id: -100_999_888,
        metadata: { 'name' => 'Мария Соколова', 'test' => true }
      )
      LeadEvent.create!(
        lead_ref: lead_ref, source: 'site_form', current_stage: 'new',
        anchor_topic_key: 'dispatcher', tg_chat_id: -1_003_779_115_845,
        metadata: { 'name' => 'Анна Петрова', 'summary' => 'хочет квартиру' }
      )

      text = described_class.new(date: Date.current).build_text
      expect(text).to match(%r{В работе: <b>1</b>})
    end
  end
end
