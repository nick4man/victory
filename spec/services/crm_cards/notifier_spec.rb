# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CrmCards::Notifier do
  let(:sent) { [] }
  let(:tg_client) do
    client = instance_double(Telegram::Client)
    allow(client).to receive(:send_message) do |text, **opts|
      sent << { text: text, chat_id: opts[:chat_id], keyboard: opts.dig(:reply_markup, :inline_keyboard) || [] }
      { 'message_id' => 1 }
    end
    allow(client).to receive(:edit_message_text).and_return(true)
    client
  end
  let(:notifier) { described_class.new(client: tg_client) }

  before { stub_crm_positions }

  let!(:agent)    { crm_staff(tg_user_id: 98_601, username: 'irina') }
  let!(:director) { crm_staff(tg_user_id: 98_602, username: 'oksana', position: '89884', role: 'director') }
  let(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1, anchor_message_id: 777,
                      assigned_to: agent, first_contact_at: 1.hour.ago)
  end
  let(:card) do
    CrmCard.create!(kind: 'lead', author: agent, lead_event: lead, status: 'pending_review', checked_at: Time.current,
                    payload: { 'name' => 'Анна', 'phone' => '79101234567', 'action' => 'sale',
                               'object_type' => 'flat', 'comment' => 'Ищет двушку до 6 млн, ипотека одобрена' })
  end

  it 'на модерацию: модератору в личку карточка с кнопками решения; карточка лида перерисована' do
    notifier.submitted(card, moderators: [director])

    dm = sent.find { |m| m[:chat_id] == director.dm_chat_id }
    expect(dm[:text]).to include('На модерацию', '@irina', 'Телефон: +7 910 123-45-67')
    expect(dm[:keyboard].flatten.map { |b| b[:callback_data] }).to include("wiz:s:crm_approve:#{card.id}")
    expect(tg_client).to have_received(:edit_message_text).with(anything, hash_including(chat_id: -100_1, message_id: 777))
  end

  it 'ни одному модератору не написать — автор узнаёт об этом сразу' do
    director.update!(dm_chat_id: nil)

    notifier.submitted(card, moderators: [director])

    expect(sent.map { |m| m[:chat_id] }).to eq([agent.dm_chat_id])
    expect(sent.last[:text]).to include('ни одному модератору')
  end

  it 'возврат: автору комментарий и карточка с кнопкой правки' do
    card.update!(status: 'needs_rework', reviewer: director)
    card.transitions.create!(from_status: 'pending_review', to_status: 'needs_rework', actor: director,
                             comment: 'Уточни бюджет')

    notifier.returned(card, comment: 'Уточни бюджет')

    expect(sent.last[:chat_id]).to eq(agent.dm_chat_id)
    expect(sent.last[:text]).to include('вернулась на доработку', 'Уточни бюджет')
    expect(sent.last[:keyboard].flatten.map { |b| b[:callback_data] }).to include("wiz:s:crm_edit:#{card.id}")
  end

  it 'выгрузка: автору и модератору номер в CRM и предупреждение' do
    card.update!(status: 'exported', crm_id: '4455', reviewer: director)

    notifier.exported(card, warning: 'ответственный не назначен')

    expect(sent.map { |m| m[:chat_id] }).to contain_exactly(agent.dm_chat_id, director.dm_chat_id)
    expect(sent.first[:text]).to include('4455', 'ответственный не назначен')
  end

  it 'сбой выгрузки: модератору кнопка повтора, автору — что повтор у модератора' do
    card.update!(status: 'export_failed', export_error: 'HTTP 502')

    notifier.export_failed(card)

    to_director = sent.find { |m| m[:chat_id] == director.dm_chat_id }
    expect(to_director[:keyboard].flatten.map { |b| b[:callback_data] }).to eq(["crm_card:#{card.id}:retry"])
    expect(sent.find { |m| m[:chat_id] == agent.dm_chat_id }[:text]).to include('кнопка повтора')
  end

  it 'сбой отправки в Telegram не роняет конвейер' do
    allow(tg_client).to receive(:send_message).and_raise(Telegram::Client::Error, 'bot was blocked')

    expect { notifier.returned(card, comment: 'Уточни бюджет') }.not_to raise_error
  end
end
