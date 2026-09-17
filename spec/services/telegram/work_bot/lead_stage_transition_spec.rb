# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::LeadStageTransition do
  let(:tg_client) do
    instance_double(Telegram::Client, send_message: { 'message_id' => 1 }, edit_message_text: { 'message_id' => 1 })
  end
  let(:agent) { TelegramUser.create!(tg_user_id: 501, role: 'agent', first_name: 'A', is_manager: false, status: 'active') }
  let(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'tg_dm', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1, anchor_message_id: 10, assigned_to: agent)
  end

  def transition(to)
    described_class.new(lead, to, actor: agent, client: tg_client).call
  end

  it '→ show ставит first_show_at один раз' do
    expect(transition('show')).to be_success
    first = lead.reload.first_show_at
    expect(first).to be_present

    described_class.new(lead, 'first_contact', actor: agent, client: tg_client).call
    transition('show')
    expect(lead.reload.first_show_at).to eq(first)
  end

  it '→ contract ставит contract_at' do
    transition('show')
    transition('contract')
    expect(lead.reload.contract_at).to be_present
  end

  it '→ first_contact не трогает first_show_at' do
    transition('first_contact')
    expect(lead.reload.first_show_at).to be_nil
  end
end
