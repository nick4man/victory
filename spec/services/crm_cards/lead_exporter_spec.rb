# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CrmCards::LeadExporter do
  let(:topnlab) { instance_double(Topnlab::Client) }
  let(:author) do
    TelegramUser.create!(tg_user_id: 98_401, tg_username: 'irina', status: 'active', email: 'irina@victory.test')
  end
  let(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1)
  end
  let(:card) do
    CrmCard.create!(kind: 'lead', author: author, lead_event: lead,
                    payload: { 'name' => 'Анна', 'phone' => '79101234567', 'action' => 'rent',
                               'object_type' => 'room', 'comment' => 'Ищет комнату у вокзала до 15 тысяч',
                               'realty_id' => 12_345 })
  end
  let(:exporter) { described_class.new(topnlab: topnlab) }

  it 'создаёт заявку и назначает ответственного по карточке' do
    allow(topnlab).to receive_messages(import_client: { 'status' => 'ok', 'insertedId' => 4455 },
                                        transfer_client: { 'status' => 'ok' })

    expect(exporter.call(card)).to have_attributes(crm_id: '4455', warning: nil)
    expect(topnlab).to have_received(:import_client).with(
      phone: '79101234567', name: 'Анна', source: 'site_form', realty_id: 12_345,
      comment: 'Ищет комнату у вокзала до 15 тысяч', action: 0, object_type: 'room'
    )
    expect(topnlab).to have_received(:transfer_client).with(order_id: 4455, email: 'irina@victory.test')
  end

  it 'продажа уходит как action: 1' do
    card.update!(payload: card.payload.merge('action' => 'sale'))
    allow(topnlab).to receive_messages(import_client: { 'status' => 'ok', 'insertedId' => 1 }, transfer_client: {})

    exporter.call(card)

    expect(topnlab).to have_received(:import_client).with(hash_including(action: 1))
  end

  it 'ответ без insertedId — ошибка, а не «успех без номера»' do
    allow(topnlab).to receive(:import_client).and_return({ 'status' => 'ok' })

    expect { exporter.call(card) }.to raise_error(Topnlab::Client::Error, /insertedId/)
  end

  it 'сбой назначения ответственного не отменяет выгрузку, а возвращается предупреждением' do
    allow(topnlab).to receive(:import_client).and_return({ 'status' => 'ok', 'insertedId' => 4455 })
    allow(topnlab).to receive(:transfer_client).and_raise(Topnlab::Client::Error, 'transferClient failed')

    outcome = exporter.call(card)

    expect(outcome.crm_id).to eq('4455')
    expect(outcome.warning).to include('ответственный не назначен')
  end

  it 'лид переназначили после отправки — ответственным в CRM становится текущий назначенный' do
    petr = TelegramUser.create!(tg_user_id: 98_402, tg_username: 'petr', status: 'active', email: 'petr@victory.test')
    lead.update!(assigned_to: petr)
    allow(topnlab).to receive_messages(import_client: { 'status' => 'ok', 'insertedId' => 4455 }, transfer_client: {})

    exporter.call(card)

    expect(topnlab).to have_received(:transfer_client).with(order_id: 4455, email: 'petr@victory.test')
  end

  it 'у автора нет email — предупреждение без вызова transfer_client' do
    author.update!(email: nil)
    allow(topnlab).to receive(:import_client).and_return({ 'status' => 'ok', 'insertedId' => 4455 })
    allow(topnlab).to receive(:transfer_client)

    expect(exporter.call(card).warning).to include('нет email')
    expect(topnlab).not_to have_received(:transfer_client)
  end
end
