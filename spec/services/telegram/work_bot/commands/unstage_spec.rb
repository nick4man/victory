# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Commands::Unstage do
  let(:tg_client) do
    # Spy с captured calls — позволяет узнать что именно reply'ит cmd.
    spy('Telegram::Client').tap do |s|
      allow(s).to receive(:send_message).and_return({ 'message_id' => 1 })
    end
  end
  let(:assignee)   { TelegramUser.create!(tg_user_id: 111, role: 'agent', first_name: 'A', last_name: 'B', is_manager: false, dm_chat_id: 111) }
  let!(:inquiry) { create(:inquiry) }
  let!(:lead) do
    LeadEvent.create!(
      lead_ref: inquiry,
      source: 'tg_dm',
      current_stage: 'show',
      anchor_topic_key: 'apartments',
      tg_chat_id: -100123,
      anchor_message_id: 9000,
      assigned_to: assignee,
      metadata: {
        'stage_history' => [
          { 'at' => 1.day.ago.iso8601, 'from' => 'new', 'to' => 'first_contact', 'by' => '@a' },
          { 'at' => 1.hour.ago.iso8601, 'from' => 'first_contact', 'to' => 'show', 'by' => '@a' }
        ]
      }
    )
  end

  def message_payload(reply_msg_id: 9000)
    {
      'chat' => { 'id' => -100123, 'type' => 'supergroup' },
      'from' => { 'id' => assignee.tg_user_id },
      'reply_to_message' => { 'message_id' => reply_msg_id },
      'text' => '/unstage'
    }
  end

  def run_cmd(msg:, user: assignee)
    # .send(:handle) bypasses Base#call's rescue StandardError wrap — иначе
    # реальные ошибки маскируются "⚠️ Ошибка: ...".
    described_class.new(message: msg, args: '', tg_user: user, client: tg_client).send(:handle)
  end

  # Helper: gather все вызовы send_message в array
  def reply_calls
    tg_client.instance_variable_get(:@_reply_calls) || []
  end

  describe '#handle' do
    it 'откатывает на previous stage из stage_history' do
      run_cmd(msg: message_payload)
      expect(lead.reload.current_stage).to eq('first_contact')
    end

    it 'appends unstage marker в stage_history' do
      run_cmd(msg: message_payload)
      hist = lead.reload.metadata['stage_history']
      last = hist.last
      expect(last['from']).to eq('show')
      expect(last['to']).to eq('first_contact')
      expect(last['unstage']).to be(true)
      expect(last['by']).to eq(assignee.mention)
    end

    it 'replies с двумя стадиями' do
      run_cmd(msg: message_payload)
      expect(tg_client).to have_received(:send_message)
        .with(a_string_including('show', 'first_contact'), anything)
    end

    it 'reject когда нет reply_to_message' do
      msg = message_payload.except('reply_to_message')
      run_cmd(msg: msg)
      expect(tg_client).to have_received(:send_message)
        .with(a_string_including('reply на якорную карточку'), anything)
      expect(lead.reload.current_stage).to eq('show') # untouched
    end

    it 'reject когда stage_history пуст' do
      lead.update!(metadata: { 'stage_history' => [] })
      run_cmd(msg: message_payload)
      expect(tg_client).to have_received(:send_message)
        .with(a_string_including('История переходов пуста'), anything)
      expect(lead.reload.current_stage).to eq('show')
    end

    it 'reject когда non-assignee non-manager' do
      other = TelegramUser.create!(tg_user_id: 222, role: 'agent', first_name: 'C', last_name: 'D', is_manager: false)
      run_cmd(msg: message_payload, user: other)
      expect(tg_client).to have_received(:send_message)
        .with(a_string_including('только assignee или manager'), anything)
      expect(lead.reload.current_stage).to eq('show')
    end
  end
end
