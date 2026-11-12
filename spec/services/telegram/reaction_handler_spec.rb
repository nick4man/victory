# frozen_string_literal: true

require 'rails_helper'

# Issue #214 (ревью PR #221, round 4): после появления второго чата
# (тестового) anchor_message_id уникален только в паре с tg_chat_id.
# Реакция в рабочем чате не должна находить probe-лида из тестового чата
# и наоборот.
RSpec.describe Telegram::ReactionHandler do
  let!(:agent) do
    TelegramUser.create!(tg_user_id: 88_001, tg_username: 'marina', first_name: 'Марина',
                         role: 'agent', status: 'active')
  end

  let(:staff_chat) { -1_003_779_115_845 }
  let(:test_chat)  { -1_002_000_000_000 }

  let!(:probe_lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'new',
                      anchor_topic_key: 'dispatcher', tg_chat_id: test_chat,
                      anchor_message_id: 42, staff_test: true)
  end

  it 'реакция в рабочем чате с тем же message_id не находит probe-лида из тестового чата' do
    expect(Telegram::WorkBot::LeadStageTransition).not_to receive(:new)

    result = described_class.new(reaction_payload(staff_chat, 42), client: double('client')).call

    expect(result).to eq(:not_on_anchor)
  end

  it 'реакция на якорь в чате, где лид опубликован, переводит его в first_contact' do
    transition = instance_double(Telegram::WorkBot::LeadStageTransition, call: true)
    expect(Telegram::WorkBot::LeadStageTransition).to receive(:new)
      .with(probe_lead, 'first_contact', actor: agent, client: anything)
      .and_return(transition)

    result = described_class.new(reaction_payload(test_chat, 42), client: double('client')).call

    expect(result).to eq(:handled)
  end

  def reaction_payload(chat_id, message_id)
    { 'chat' => { 'id' => chat_id },
      'message_id' => message_id,
      'user' => { 'id' => agent.tg_user_id },
      'new_reaction' => [{ 'type' => 'emoji', 'emoji' => '👍' }] }
  end
end
