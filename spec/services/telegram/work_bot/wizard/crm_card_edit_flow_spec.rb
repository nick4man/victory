# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Wizard::CrmCardEditFlow do
  include_context 'wizard DM harness'

  before do
    stub_crm_positions
    allow(DispatcherDigestRefreshJob).to receive(:perform_async)
  end

  let!(:agent)    { crm_staff(tg_user_id: 98_931, username: 'irina') }
  let!(:director) { crm_staff(tg_user_id: 98_932, username: 'oksana', position: '89884', role: 'director') }
  let(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1, assigned_to: agent,
                      first_contact_at: 1.hour.ago)
  end
  let!(:card) do
    CrmCards::Workflow.new(notifier: instance_double(CrmCards::Notifier)).upsert_lead_card!(
      lead: lead, actor: agent,
      values: { 'name' => 'Анна', 'phone' => '79101234567', 'action' => 'sale', 'object_type' => 'flat',
                'comment' => 'Ищет двушку до 6 млн, ипотека одобрена' }
    ).card
  end

  it 'автор меняет телефон: неверный ввод не сбрасывает шаг, верный нормализуется и перепроверяется' do
    tap_callback("wiz:s:crm_edit:#{card.id}", user: agent)
    press('Телефон', user: agent)

    say('12345', user: agent)
    expect(last_text).to include('нужно 11', 'Шаг не сброшен')

    say('8 (920) 555-44-33', user: agent)
    expect(last_text).to include('Сохранить «Телефон: +7 920 555-44-33»?')
    press('Сохранить', user: agent)

    expect(card.reload.payload['phone']).to eq('79205554433')
    expect(last_text).to include('Телефон: +7 920 555-44-33', 'всё на месте')
  end

  it 'необязательное поле можно очистить кнопкой' do
    card.update!(payload: card.payload.merge('realty_id' => 12_345))

    tap_callback("wiz:s:crm_edit:#{card.id}", user: agent)
    press('ID объекта', user: agent)
    press('Очистить', user: agent)
    press('Сохранить', user: agent)

    expect(card.reload.payload).not_to have_key('realty_id')
  end

  it 'у обязательного поля кнопки «Очистить» нет' do
    tap_callback("wiz:s:crm_edit:#{card.id}", user: agent)
    press('Имя клиента', user: agent)

    expect(dms.last[:keyboard].flatten.map { |b| b[:text] }).not_to include('🗑 Очистить')
  end

  it 'на модерации автор править не может, модератор — может' do
    card.update!(status: 'pending_review')

    tap_callback("wiz:s:crm_edit:#{card.id}", user: agent)
    expect(last_text).to include('только модератор')

    tap_callback("wiz:s:crm_edit:#{card.id}", user: director)
    expect(last_text).to include("Какое поле карточки ##{card.id} изменить?")
  end
end
