# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CrmCards::PhoneMatches do
  before { stub_crm_positions }

  let!(:agent) { crm_staff(tg_user_id: 98_301, username: 'irina') }

  it 'ничего не нашлось — пустой список' do
    expect(described_class.for('79101234567')).to eq([])
  end

  it 'номер из заявки с сайта: номер заявки, дата и ответственный' do
    inquiry = create(:inquiry, client_phone_e164: '79101234567', created_at: Time.zone.parse('2026-09-12 10:00'))
    LeadEvent.create!(lead_ref: inquiry, source: 'site_form', current_stage: 'new', anchor_topic_key: 'apartments',
                      tg_chat_id: -100_1, assigned_to: agent)

    lines = described_class.for('79101234567')

    expect(lines.first).to include("##{inquiry.id}", '12.09.26', '@irina')
  end

  it 'номер из другой карточки конвейера; свою карточку не показывает' do
    other = CrmCard.create!(kind: 'lead', author: agent, status: 'pending_review',
                            payload: { 'name' => 'Анна', 'phone' => '79101234567' })
    mine = CrmCard.create!(kind: 'lead', author: agent, payload: { 'phone' => '79101234567' })

    lines = described_class.for('79101234567', card: mine)

    expect(lines.join).to include("##{other.id}", 'На модерации')
    expect(lines.join).not_to include("##{mine.id}")
  end

  it 'второй номер клиента тоже считается совпадением' do
    other = CrmCard.create!(kind: 'lead', author: agent, payload: { 'phone_extra' => '74912123456' })

    expect(described_class.for('74912123456').join).to include("##{other.id}")
  end

  it 'номер в стоп-листе — первой строкой' do
    PhoneStopList.add!(phone: '79101234567', reason: 'просил не звонить')

    expect(described_class.for('79101234567').first).to include('стоп-листе')
  end

  it 'ненормализованный номер не ищется' do
    expect(described_class.for('8977842598')).to eq([])
  end
end
