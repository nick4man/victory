# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Wizard::CrmLeadCardFlow do
  include_context 'wizard DM harness'

  before do
    stub_crm_positions
    allow(DispatcherDigestRefreshJob).to receive(:perform_async)
  end

  let!(:agent) { crm_staff(tg_user_id: 98_901, username: 'irina') }
  let!(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -1_003_779_115_845, anchor_message_id: 555,
                      assigned_to: agent, first_contact_at: 1.hour.ago,
                      metadata: { 'name' => 'Анна Смирнова', 'phone' => '+79101234567' })
  end

  it 'с кнопки под лидом: имя и телефон из заявки не спрашивает, остальное — по шагам' do
    tap_callback("wiz:s:crm_lead:#{lead.id}", user: agent, chat_type: 'supergroup')
    expect(acks.last.first).to include('личке')
    expect(last_text).to include('Что нужно клиенту?')

    press('Продажа', user: agent)
    expect(last_text).to include('Тип объекта?')

    press('Квартира', user: agent)
    expect(last_text).to include('Итог разговора с клиентом?')

    say('коротко', user: agent)
    expect(last_text).to include('Слишком коротко', 'Шаг не сброшен')

    say('Ищет двушку в Канищево до 6 млн, ипотека одобрена', user: agent)
    expect { press('Сохранить', user: agent) }.to change(CrmCard, :count).by(1)

    card = CrmCard.last
    expect(card).to have_attributes(author_id: agent.id, lead_event_id: lead.id, status: 'draft')
    expect(card.payload).to include('name' => 'Анна Смирнова', 'phone' => '79101234567',
                                    'action' => 'sale', 'object_type' => 'flat')
    expect(last_text).to include('✅ пройдена')
    expect(last_callbacks).to include("crm_card:#{card.id}:submit")
  end

  it 'по черновику спрашивает только незаполненное' do
    CrmCard.create!(kind: 'lead', author: agent, lead_event: lead,
                    payload: { 'name' => 'Анна', 'phone' => '79101234567', 'action' => 'rent', 'object_type' => 'room' })

    tap_callback("wiz:s:crm_lead:#{lead.id}", user: agent)

    expect(last_text).to include('Итог разговора с клиентом?')
  end

  it 'не ответственный по лиду получает отказ до первого вопроса' do
    petr = crm_staff(tg_user_id: 98_902, username: 'petr')

    tap_callback("wiz:s:crm_lead:#{lead.id}", user: petr)

    expect(last_text).to include('заполняет ответственный', '@irina')
    expect(petr.reload.pending_action).to be_nil
  end

  it 'должность без прав в CRM — отказ с причиной' do
    auditor = crm_staff(tg_user_id: 98_903, username: 'audit', position: '40')
    lead.update!(assigned_to: auditor)

    tap_callback("wiz:s:crm_lead:#{lead.id}", user: auditor)

    expect(last_text).to include('не выданы права')
  end

  it 'карточка уже на модерации — мастер не стартует' do
    card = CrmCard.create!(kind: 'lead', author: agent, lead_event: lead, status: 'pending_review')

    tap_callback("wiz:s:crm_lead:#{lead.id}", user: agent)

    expect(last_text).to include("Карточка ##{card.id}", 'На модерации')
  end

  it 'закрытый лид — мастер не стартует' do
    lead.update!(current_stage: 'closed_lost')

    tap_callback("wiz:s:crm_lead:#{lead.id}", user: agent)

    expect(last_text).to include('уже закрыт')
    expect(agent.reload.pending_action).to be_nil
  end
end
