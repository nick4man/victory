# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Wizard::CrmCardManualExportFlow do
  include_context 'wizard DM harness'

  before { stub_crm_positions }

  let!(:agent)    { crm_staff(tg_user_id: 98_981, username: 'irina') }
  let!(:director) { crm_staff(tg_user_id: 98_982, username: 'oksana', position: '89884', role: 'director') }
  let!(:card) do
    CrmCard.create!(kind: 'object', author: agent, reviewer: director, status: 'approved', export_mode: 'manual',
                    checked_at: Time.current,
                    payload: { 'owner_name' => 'Иванов Пётр', 'owner_phone' => '79100001122', 'action' => 'sale',
                               'realty_type' => 'flat', 'address' => 'Рязань, ул. Есенина, 29', 'price' => 5_500_000,
                               'area_common' => 54.3, 'rooms' => 2, 'contract_type' => 'verbal' })
  end

  it 'автор получает паспорт для внесения и отмечает номер карточки CRM' do
    CrmCards::Notifier.new(client: tg_client).approved(card)
    expect(last_text).to include('Объект одобрен', 'Внеси объект в CRM вручную', 'Собственник: Иванов Пётр')

    press('Внесено в CRM', user: agent)
    say('номер 123', user: agent)
    expect(last_text).to include('только цифры')

    say('998877', user: agent)
    press('Подтвердить', user: agent)

    expect(card.reload).to have_attributes(status: 'exported', crm_id: '998877', export_mode: 'manual')
    expect(card.transitions.last).to have_attributes(to_status: 'exported', actor_id: agent.id)
  end

  it 'номер, уже отмеченный у другого объекта, не принимается' do
    CrmCard.create!(kind: 'object', author: agent, status: 'exported', export_mode: 'manual', crm_id: '998877',
                    payload: { 'owner_name' => 'Другой' })
    CrmCards::Notifier.new(client: tg_client).approved(card)

    press('Внесено в CRM', user: agent)
    say('998877', user: agent)

    expect(last_text).to include('уже отмечен у объекта')
    expect(card.reload).to be_status_approved
  end

  it 'посторонний отметить внесение не может' do
    petr = crm_staff(tg_user_id: 98_983, username: 'petr')

    tap_callback("wiz:s:crm_manual:#{card.id}", user: petr)

    expect(last_text).to include('автор карточки или модератор')
    expect(card.reload).to be_status_approved
  end
end
