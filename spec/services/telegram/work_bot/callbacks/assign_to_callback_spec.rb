# frozen_string_literal: true

require 'rails_helper'

# Phase 16.7 — фокус на BotCommandLog.error_message для soft-errors
# (assignee_not_found / lead_assignment_failed). До фикса callbacks_router
# логировал result=ok даже когда callback вернул ack('⚠️ ...').
RSpec.describe Telegram::WorkBot::Callbacks::AssignToCallback do
  let!(:manager) do
    TelegramUser.create!(
      tg_user_id: 50_001, tg_username: 'mgr', first_name: 'Mgr',
      role: 'manager', is_manager: true, status: 'active'
    )
  end

  let!(:lead) do
    user = User.find_or_create_by!(email: "stub-#{SecureRandom.hex(4)}@stub.local") do |u|
      u.password = SecureRandom.urlsafe_base64(20)
      u.first_name = 'Test'; u.last_name = 'Stub'; u.role = :client; u.active = true
    end
    LeadEvent.create!(
      lead_ref: user, source: 'site_form', current_stage: 'new',
      anchor_topic_key: 'apartments', tg_chat_id: -1_003_779_115_845,
      metadata: { 'name' => 'Test' }
    )
  end

  let(:tg_client) { instance_double(Telegram::Client, answer_callback_query: { 'ok' => true }) }

  def callback_query(args:)
    {
      'id' => '1234',
      'from' => { 'id' => 50_001 },
      'message' => { 'chat' => { 'id' => -1_003_779_115_845 }, 'message_id' => 999 },
      'data' => "assign_to:#{args.join(':')}"
    }
  end

  def invoke(callback_args)
    described_class.new(
      callback_query: callback_query(args: callback_args),
      tg_user: manager,
      args: callback_args,
      client: tg_client
    ).call
  end

  describe 'soft-error BotCommandLog.error_message' do
    it 'assignee_not_found — пишет error_message' do
      missing_user_id = 999_999
      expect {
        invoke([lead.id.to_s, missing_user_id.to_s])
      }.to change(BotCommandLog, :count).by(1)

      log = BotCommandLog.last
      expect(log.command).to eq('callback:assign_to:soft_error')
      expect(log.result).to eq('assignee_not_found')
      expect(log.error_message).to include('lead=')
      expect(log.error_message).to include(missing_user_id.to_s)
    end

    it 'lead_assignment_failed — пишет error_message с описанием' do
      assignee = TelegramUser.create!(
        tg_user_id: 50_002, tg_username: 'agent', first_name: 'Agent',
        role: 'agent', is_manager: false, status: 'active'
      )
      fake_result = double('Result', success?: false, error_message: 'CRM rejected')
      allow_any_instance_of(Telegram::WorkBot::LeadAssignment).to receive(:call).and_return(fake_result)

      expect {
        invoke([lead.id.to_s, assignee.id.to_s])
      }.to change(BotCommandLog, :count).by(1)

      log = BotCommandLog.last
      expect(log.result).to eq('lead_assignment_failed')
      expect(log.error_message).to include('CRM rejected')
    end

    it 'happy path — НЕ создаёт soft_error log (только reassignment если был prev)' do
      assignee = TelegramUser.create!(
        tg_user_id: 50_003, tg_username: 'agent2', first_name: 'Agent2',
        role: 'agent', is_manager: false, status: 'active'
      )
      fake_result = double('Result', success?: true, error_message: nil)
      allow_any_instance_of(Telegram::WorkBot::LeadAssignment).to receive(:call).and_return(fake_result)

      expect {
        invoke([lead.id.to_s, assignee.id.to_s])
      }.not_to(change { BotCommandLog.where(result: 'assignee_not_found').count })
      expect(BotCommandLog.where(result: 'lead_assignment_failed').count).to eq(0)
    end
  end
end
