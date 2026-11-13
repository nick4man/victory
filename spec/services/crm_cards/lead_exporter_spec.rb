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

  it 'второй номер клиента дописывается в комментарий заявки' do
    card.update!(payload: card.payload.merge('phone_extra' => '74912123456'))
    allow(topnlab).to receive_messages(import_client: { 'status' => 'ok', 'insertedId' => 4455 }, transfer_client: true)

    exporter.call(card)

    expect(topnlab).to have_received(:import_client).with(hash_including(comment: a_string_including('Доп. телефон: +74912123456')))
  end

  it 'продажа уходит как action: 1' do
    card.update!(payload: card.payload.merge('action' => 'sale'))
    allow(topnlab).to receive_messages(import_client: { 'status' => 'ok', 'insertedId' => 1 }, transfer_client: {})

    exporter.call(card)

    expect(topnlab).to have_received(:import_client).with(hash_including(action: 1))
  end

  it 'ответ без insertedId — неоднозначный исход, а не «успех без номера»' do
    allow(topnlab).to receive(:import_client).and_return({ 'status' => 'ok' })

    expect { exporter.call(card) }.to raise_error(Topnlab::Client::AmbiguousError, /insertedId/)
  end

  it 'невалидный (нечисловой) insertedId — тоже неоднозначный исход: номер не доезжает в БД и лог' do
    allow(topnlab).to receive(:import_client).and_return({ 'status' => 'ok', 'insertedId' => 'abc<script>' })

    expect { exporter.call(card) }.to raise_error(Topnlab::Client::AmbiguousError, /insertedId/)
  end

  it 'сбой назначения ответственного не отменяет выгрузку, а возвращается предупреждением' do
    allow(topnlab).to receive(:import_client).and_return({ 'status' => 'ok', 'insertedId' => 4455 })
    allow(topnlab).to receive(:transfer_client).and_raise(Topnlab::Client::Error, 'transferClient failed')

    outcome = exporter.call(card)

    expect(outcome.crm_id).to eq('4455')
    expect(outcome.warning).to include('ответственный не назначен')
  end

  it 'сырой сетевой сбой назначения тоже не теряет номер заявки' do
    allow(topnlab).to receive(:import_client).and_return({ 'status' => 'ok', 'insertedId' => 4455 })
    allow(topnlab).to receive(:transfer_client).and_raise(Errno::ECONNREFUSED)

    outcome = exporter.call(card)

    expect(outcome.crm_id).to eq('4455')
    expect(outcome.warning).to include('ответственный не назначен', 'ECONNREFUSED')
  end

  # Сквозной регресс ревью PR #210 (блокер 2): ошибочный ответ CRM может
  # отразить appkey запроса. Реальный клиент (не double) scrub'ит тело на
  # raise, поэтому предупреждение — единственный носитель ошибки в
  # export_error/журнал/Telegram — секрета не содержит.
  it 'appkey, отражённый в ошибке transfer_client, не доезжает до warning' do
    real_client = Topnlab::Client.new(api_key: 'test-key', base_url: 'https://crm.example')
    stub_request(:post, %r{\Ahttps://crm\.example/call/main/importClient/})
      .to_return(status: 200, body: { status: 'ok', insertedId: 4455 }.to_json)
    stub_request(:post, %r{\Ahttps://crm\.example/call/main/transferClient/})
      .to_return(status: 200, body: { status: 'error', message: 'no agent key=test-key' }.to_json)

    outcome = described_class.new(topnlab: real_client).call(card)

    expect(outcome.crm_id).to eq('4455')
    expect(outcome.warning).to include('ответственный не назначен')
    expect(outcome.warning).not_to include('test-key')
    expect(outcome.warning).to include('[FILTERED]')
  end

  # Сквозной регресс ревью PR #210 (round 9, блокер 1): email агента из
  # тела запроса, отражённый CRM в message ошибки transfer_client, не должен
  # доехать до Outcome#warning → журнал/export_error/Telegram.
  it 'email агента, отражённый в ошибке transfer_client, не доезжает до warning' do
    real_client = Topnlab::Client.new(api_key: 'test-key', base_url: 'https://crm.example')
    stub_request(:post, %r{\Ahttps://crm\.example/call/main/importClient/})
      .to_return(status: 200, body: { status: 'ok', insertedId: 4455 }.to_json)
    stub_request(:post, %r{\Ahttps://crm\.example/call/main/transferClient/})
      .to_return(status: 200, body: { status: 'error', message: 'no such agent irina@victory.test' }.to_json)

    outcome = described_class.new(topnlab: real_client).call(card)

    expect(outcome.crm_id).to eq('4455')
    expect(outcome.warning).to include('ответственный не назначен')
    expect(outcome.warning).not_to include('irina@victory.test')
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

  # Регресс ревью #94: Topnlab::Client#import_client режет comment до 500
  # символов, поэтому суффикс с телефоном обязан пережить усечение. Проверяем
  # итоговое тело HTTP-запроса к Topnlab, а не аргумент до усечения.
  it 'длинный комментарий: итоговое тело запроса ≤ 500 символов и доп. телефон доезжает целиком' do
    card.update!(payload: card.payload.merge('phone_extra' => '74912123456', 'comment' => 'Ж' * 600))
    sent_comment = nil
    stub_request(:post, %r{\Ahttps://crm\.example/call/main/importClient/})
      .with { |req| sent_comment = JSON.parse(req.body)['comment'] }
      .to_return(status: 200, body: { status: 'ok', insertedId: 4455 }.to_json)
    stub_request(:post, %r{\Ahttps://crm\.example/call/main/transferClient/})
      .to_return(status: 200, body: { status: 'ok' }.to_json)
    real_client = Topnlab::Client.new(api_key: 'test-key', base_url: 'https://crm.example')

    described_class.new(topnlab: real_client).call(card)

    expect(sent_comment).to be_present
    expect(sent_comment.length).to be <= 500
    expect(sent_comment).to end_with("Доп. телефон: +74912123456")
    expect(sent_comment).to start_with('Ж')
  end
end
