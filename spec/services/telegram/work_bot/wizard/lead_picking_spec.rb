# frozen_string_literal: true

require 'rails_helper'

# LeadPicking (task/close мастера рабочего бота) не должен ни показывать, ни
# принимать тестовые лиды песочницы (metadata['sandbox']) — они существуют
# только для проверки конвейера карточек CRM в тестовом боте.
RSpec.describe 'LeadPicking — изоляция тестовых лидов в рабочем боте' do
  include_context 'wizard DM harness'

  before { allow(DispatcherDigestRefreshJob).to receive(:perform_async) }

  let!(:agent) do
    TelegramUser.create!(tg_user_id: 96_301, tg_username: 'oleg', first_name: 'Олег',
                         role: 'agent', status: 'active', dm_chat_id: 96_301)
  end
  let!(:real_lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'first_contact',
                      first_contact_at: 1.hour.ago, anchor_topic_key: 'apartments', tg_chat_id: -100_3,
                      assigned_to: agent, metadata: { 'name' => 'Анна Реальная' })
  end
  let!(:sandbox_lead) do
    LeadEvent.create!(lead_ref: agent, source: 'manual', current_stage: 'first_contact',
                      first_contact_at: 1.hour.ago, anchor_topic_key: 'dispatcher', tg_chat_id: agent.dm_chat_id,
                      assigned_to: agent, staff_test: true, metadata: { 'name' => 'Тест Тестович', 'sandbox' => true })
  end

  def labels
    dms.last[:keyboard].flatten.map { |b| b[:text] }
  end

  it 'из меню: тестовый лид не попадает в список последних открытых' do
    tap_callback('wiz:s:task', user: agent)

    expect(last_text).to include('По какому лиду?')
    joined = labels.join
    expect(joined).to include("##{real_lead.id}").and(satisfy { |t| !t.include?("##{sandbox_lead.id}") })
  end

  it 'ручной ввод номера тестового лида отказывает, шаг не сбрасывается' do
    tap_callback('wiz:s:task', user: agent)
    press('Ввести номер лида', user: agent)

    say(sandbox_lead.id.to_s, user: agent)

    expect(last_text).to include("Лид ##{sandbox_lead.id} тестовый", 'только в тестовом боте')
    expect(agent.reload.pending_action).not_to be_nil # мастер не отменился, шаг тот же
  end

  it 'подделанный id тестового лида с кнопки-якоря (task-callback) тоже отказывает' do
    tap_callback("wiz:s:task:#{sandbox_lead.id}", user: agent)

    expect(last_text).to include("Лид ##{sandbox_lead.id} тестовый", 'только в тестовом боте')
    expect(agent.reload.pending_action).to be_nil
  end
end
