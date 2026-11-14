# frozen_string_literal: true

require 'rails_helper'

# Issue #224 (ревью PR #221, round 5, блокер 3): #ахтунг — боевой сигнал.
# Из тестового чата (и любого чата кроме рабочей группы) менеджерам DM не
# уходят, priority у карточек не меняется.
RSpec.describe Telegram::WorkBot::HashtagHandler do
  let(:tg_client) do
    instance_double(Telegram::Client, send_message: { 'message_id' => 1 },
                                     edit_message_text: { 'message_id' => 1 })
  end
  let!(:manager) do
    TelegramUser.create!(tg_user_id: 97_001, tg_username: 'dir', first_name: 'Дир',
                         role: 'director', is_manager: true, status: 'active', dm_chat_id: 97_001)
  end
  let(:work_chat) { Telegram::WorkBot::Router::WORK_CHAT_ID }
  let(:test_chat)  { -1_002_000_000_000 }

  def msg(chat_id, text:, reply_to: nil)
    m = { 'message_id' => 5, 'chat' => { 'id' => chat_id, 'type' => 'supergroup' },
          'from' => { 'id' => 99, 'username' => 'agent1' }, 'text' => text }
    m['reply_to_message'] = { 'message_id' => reply_to } if reply_to
    m
  end

  it 'в рабочей группе шлёт DM менеджерам (в т.ч. без reply на карточку)' do
    result = described_class.new(msg(work_chat, text: 'Клиент уходит #ахтунг'), client: tg_client).call

    expect(result).to eq(:handled)
    expect(tg_client).to have_received(:send_message)
      .with(a_string_including('#ахтунг'), hash_including(chat_id: manager.dm_chat_id))
  end

  it 'в тестовом чате без reply — игнор, DM менеджерам не уходят' do
    result = described_class.new(msg(test_chat, text: '#ахтунг тестовый прогон'), client: tg_client).call

    expect(result).to eq(:ignored)
    expect(tg_client).not_to have_received(:send_message)
  end

  it 'в тестовом чате reply на карточку test-лида — игнор, priority не меняется' do
    lead = LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'new',
                             anchor_topic_key: 'dispatcher', tg_chat_id: test_chat,
                             anchor_message_id: 900, staff_test: true)

    result = described_class.new(msg(test_chat, text: '#ахтунг', reply_to: 900), client: tg_client).call

    expect(result).to eq(:ignored)
    expect(tg_client).not_to have_received(:send_message)
    expect(lead.reload.metadata['priority']).to be_nil
  end
end
