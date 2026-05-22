# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ChatTools::Staff::SearchAllLeads do
  let!(:director) do
    TelegramUser.create!(tg_user_id: 80_001, tg_username: 'dir', first_name: 'Dir',
                         role: 'director', is_manager: true, status: 'active')
  end
  let!(:agent) do
    TelegramUser.create!(tg_user_id: 80_002, tg_username: 'ag', first_name: 'Agent',
                         role: 'agent', is_manager: false, status: 'active')
  end

  # Минимальный stub для polymorphic lead_ref — используем User модель.
  let(:lead_ref) do
    User.find_or_create_by!(email: "stub-#{SecureRandom.hex(4)}@victory.ru") do |u|
      u.password = SecureRandom.urlsafe_base64(20)
      u.first_name = 'Test'
      u.last_name = 'Stub'
      u.role = :client
      u.active = true
    end
  end

  before do
    LeadEvent.create!(
      lead_ref: lead_ref, source: 'site_form', current_stage: 'new',
      anchor_topic_key: 'apartments', tg_chat_id: -1_003_779_115_845,
      assigned_to_id: agent.id, assigned_by_id: director.id,
      metadata: { 'name' => 'Анна Петрова', 'summary' => 'хочет квартиру в Канищево 8.5М' }
    )
    LeadEvent.create!(
      lead_ref: lead_ref, source: 'site_valuation', current_stage: 'closed_won',
      anchor_topic_key: 'houses', tg_chat_id: -1_003_779_115_845,
      assigned_to_id: agent.id,
      metadata: { 'name' => 'Сергей', 'summary' => 'дом в Солотче — закрыта' }
    )
  end

  describe '#call' do
    context 'director' do
      it 'находит лиды по FTS query' do
        res = described_class.call({ query: 'Канищево' }, asked_by: director)
        expect(res[:count]).to eq(1)
        expect(res[:items].first[:summary]).to include('Канищево')
      end

      it 'учитывает русскую морфологию' do
        # «квартира» в text должна найти лид со словом «квартиру»
        res = described_class.call({ query: 'квартира' }, asked_by: director)
        expect(res[:count]).to eq(1)
      end

      it 'фильтрует только open' do
        res = described_class.call({ only_open: true }, asked_by: director)
        expect(res[:count]).to eq(1)
        expect(res[:items].first[:stage]).to eq('new')
      end

      it 'фильтрует по assigned_username' do
        res = described_class.call({ assigned_username: 'ag' }, asked_by: director)
        expect(res[:count]).to eq(2)
      end

      it 'фильтрует по assigned_by_username (Iter 59 FK)' do
        res = described_class.call({ assigned_by_username: 'dir' }, asked_by: director)
        expect(res[:count]).to eq(1) # только первый, у второго assigned_by_id = nil
      end

      it 'фильтрует по current_stage' do
        res = described_class.call({ current_stage: 'closed_won' }, asked_by: director)
        expect(res[:count]).to eq(1)
        expect(res[:items].first[:stage]).to eq('closed_won')
      end
    end

    context 'agent (silent self-only)' do
      it 'видит только свои (assigned_to_id = caller)' do
        res = described_class.call({ assigned_username: 'dir' }, asked_by: agent)
        expect(res[:count]).to eq(2) # agent видит свои leads — оба assigned_to_id = agent
      end
    end
  end
end
