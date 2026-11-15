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

  let!(:real_lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'new',
                      anchor_topic_key: 'dispatcher', tg_chat_id: staff_chat,
                      anchor_message_id: 43)
  end

  it 'реакция в рабочем чате с тем же message_id не находит probe-лида из тестового чата' do
    expect(Telegram::WorkBot::LeadStageTransition).not_to receive(:new)

    result = described_class.new(reaction_payload(staff_chat, 42), client: double('client')).call

    expect(result).to eq(:not_on_anchor)
  end

  it 'реакция на якорь боевого лида переводит его в first_contact' do
    transition = instance_double(Telegram::WorkBot::LeadStageTransition, call: true)
    expect(Telegram::WorkBot::LeadStageTransition).to receive(:new)
      .with(real_lead, 'first_contact', actor: agent, client: anything)
      .and_return(transition)

    result = described_class.new(reaction_payload(staff_chat, 43), client: double('client')).call

    expect(result).to eq(:handled)
  end

  # Issue #224 (ревью PR #221, round 5, блокер): реакция на probe-карточку
  # не двигает стадию — LeadStageTransition шлёт стадию в CRM и при
  # ENABLE_LEAD_STAGE_BROADCAST=true создаёт клиентские уведомления.
  it 'реакция на probe-карточку не переводит лид в first_contact' do
    expect(Telegram::WorkBot::LeadStageTransition).not_to receive(:new)

    result = described_class.new(reaction_payload(test_chat, 42), client: double('client')).call

    expect(result).to eq(:handled)
    expect(probe_lead.reload.current_stage).to eq('new')
  end

  # Issue #224 (ревью PR #221, round 5, блокер 1): реакция закрывает задачу
  # только в DM исполнителя. message_id уникален лишь внутри чата — 👍 в
  # тестовом чате с тем же ID не должен закрыть боевую задачу из DM.
  describe 'task-reaction изоляция (round 5)' do
    let!(:dm_task) do
      ::Task.create!(assignee: agent, title: 'Боевая задача', status: 'open',
                     kind: 'other', priority: 'normal', tg_message_id: 777)
    end

    it '👍 на то же message_id в тестовом чате НЕ закрывает боевую задачу из DM' do
      result = described_class.new(reaction_payload(test_chat, 777), client: double('client')).call

      expect(dm_task.reload.status_open?).to be(true)
      expect(result).not_to eq(:task_completed)
    end

    it '👍 в DM исполнителя по-прежнему закрывает задачу' do
      result = described_class.new(reaction_payload(agent.tg_user_id, 777), client: double('client')).call

      expect(dm_task.reload.status_open?).to be(false)
      expect(result).to eq(:task_completed)
    end
  end

  def reaction_payload(chat_id, message_id)
    { 'chat' => { 'id' => chat_id },
      'message_id' => message_id,
      'user' => { 'id' => agent.tg_user_id },
      'new_reaction' => [{ 'type' => 'emoji', 'emoji' => '👍' }] }
  end
end
