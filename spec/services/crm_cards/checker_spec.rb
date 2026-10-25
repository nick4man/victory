# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CrmCards::Checker do
  let(:agent) { TelegramUser.create!(tg_user_id: 98_301, tg_username: 'irina', role: 'agent', status: 'active') }
  let(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1, assigned_to: agent,
                      first_contact_at: 1.hour.ago)
  end
  let(:valid_payload) do
    { 'name' => 'Анна', 'phone' => '79101234567', 'action' => 'sale', 'object_type' => 'flat',
      'comment' => 'Ищет двушку в Канищево до 6 млн, ипотека одобрена' }
  end

  def check(payload, lead_event: lead)
    described_class.call(CrmCard.new(kind: 'lead', author: agent, lead_event: lead_event, payload: payload))
  end

  it 'полная карточка по лиду после контакта — без замечаний' do
    expect(check(valid_payload)).to eq([])
  end

  it 'пустые обязательные поля перечислены, необязательные — нет' do
    fields = check({}).map { |e| e['field'] }

    expect(fields).to include('name', 'phone', 'action', 'object_type', 'comment')
    expect(fields).not_to include('realty_id')
  end

  it 'итог разговора короче 20 символов не проходит' do
    expect(check(valid_payload.merge('comment' => 'перезвонить'))).to contain_exactly(
      a_hash_including('field' => 'comment', 'message' => a_string_including('от 20'))
    )
  end

  it 'лид на стадии «новый» без отметки контакта — это и есть спам-фильтр' do
    lead.update!(current_stage: 'new', first_contact_at: nil)

    expect(check(valid_payload)).to contain_exactly(
      a_hash_including('field' => 'lead', 'message' => a_string_including('не связывались'))
    )
  end

  it 'отметка контакта без смены стадии тоже считается контактом' do
    lead.update!(current_stage: 'new', first_contact_at: 10.minutes.ago)

    expect(check(valid_payload)).to eq([])
  end

  it 'неназначенный и закрытый лиды' do
    lead.update!(assigned_to: nil, current_stage: 'closed_lost')

    expect(check(valid_payload).map { |e| e['message'] }).to include(
      a_string_including('никому не назначен'), a_string_including('Лид закрыт')
    )
  end

  it 'пометка staff_test не блокирует: её ставит эвристика, в том числе клиенту с именем сотрудника' do
    lead.update!(staff_test: true, staff_test_matched_by: 'name_staff_first')

    expect(check(valid_payload)).to eq([])
  end

  it 'клиент уже в CRM — вторую заявку не пропускает' do
    lead.lead_ref.update_columns(crm_id: '4455')

    expect(check(valid_payload).map { |e| e['message'] }).to include(a_string_including('4455'))
  end

  it 'карточка заявки без лида' do
    expect(check(valid_payload, lead_event: nil)).to contain_exactly(
      a_hash_including('field' => 'lead', 'message' => 'Карточка не привязана к лиду.')
    )
  end

  it 'повторная проверка сохранённых значений идемпотентна' do
    expect(check(valid_payload.merge('realty_id' => 12_345))).to eq([])
  end
end
