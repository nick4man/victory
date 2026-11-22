# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Wizard::CrmCardAttachFlow do
  include_context 'wizard DM harness'

  before { stub_crm_positions }

  let!(:agent)    { crm_staff(tg_user_id: 98_971, username: 'irina') }
  let!(:director) { crm_staff(tg_user_id: 98_972, username: 'oksana', position: '89884', role: 'director') }
  let(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_9, assigned_to: agent,
                      first_contact_at: 1.hour.ago)
  end
  let!(:card) do
    CrmCard.create!(kind: 'lead', author: agent, lead_event: lead, status: 'export_failed',
                    export_error: 'Net::ReadTimeout', export_retryable: false, checked_at: Time.current,
                    released_by: director, released_at: 30.minutes.ago,
                    payload: { 'name' => 'Анна', 'phone' => '79101234567', 'action' => 'sale',
                               'object_type' => 'flat' })
  end

  it 'кнопка «Номер из CRM» на карточке приводит в мастер, а не в «Неизвестный мастер»' do
    view = CrmCards::CardView.render(card, viewer: director)

    expect(view[:keyboard].flatten.map { |b| b[:callback_data] }).to include("wiz:s:crm_attach:#{card.id}")
    tap_callback("wiz:s:crm_attach:#{card.id}", user: director)
    expect(last_text).to include('Номер заявки в CRM по карточке')
  end

  it 'модератор сверяет CRM и привязывает номер — карточка становится выгруженной' do
    tap_callback("wiz:s:crm_attach:#{card.id}", user: director)

    say('номер 4242abc', user: director)
    expect(last_text).to include('только цифры')

    say('7788', user: director)
    press('Привязать', user: director)

    expect(card.reload).to have_attributes(status: 'exported', crm_id: '7788')
    expect(last_text).to include('В CRM', '7788')
    expect(card.transitions.last).to have_attributes(to_status: 'exported', actor_id: director.id)
  end

  it 'номер с буквами не принимается, карточка не меняется' do
    tap_callback("wiz:s:crm_attach:#{card.id}", user: director)
    say('4242abc', user: director)

    expect(card.reload).to be_status_export_failed
    expect(card.crm_id).to be_nil
  end

  it 'не-модератору кнопка отвечает отказом, номер не привязывается' do
    tap_callback("wiz:s:crm_attach:#{card.id}", user: agent)

    expect(last_text).to include('Привязку номера делает модератор')
    expect(card.reload).to be_status_export_failed
  end

  it 'карточку без сбоя выгрузки привязывать нечего' do
    card.update!(status: 'pending_review')

    tap_callback("wiz:s:crm_attach:#{card.id}", user: director)

    expect(last_text).to include('Привязывать нечего')
    expect(card.reload).to be_status_pending_review
  end
end
