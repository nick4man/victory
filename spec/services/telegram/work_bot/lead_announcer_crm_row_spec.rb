# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable RSpec/DescribeMethod, RSpec/SpecFilePathFormat -- второй аргумент describe группирует
# спеку по фиче (кнопка карточки CRM под лидом), а не по одному методу.
RSpec.describe Telegram::WorkBot::LeadAnnouncer, 'кнопка карточки CRM' do
  let(:agent) { TelegramUser.create!(tg_user_id: 98_911, tg_username: 'irina', role: 'agent', status: 'active') }
  let(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1, assigned_to: agent)
  end

  def crm_buttons
    described_class.new(lead, client: instance_double(Telegram::Client)).keyboard_for_card[:inline_keyboard]
                   .flatten.select { |b| b[:text].include?('CRM') }
  end

  it 'лид без карточки — кнопка мастера заявки' do
    expect(crm_buttons.map { |b| b[:callback_data] }).to eq(["wiz:s:crm_lead:#{lead.id}"])
  end

  it 'возвращённая карточка — та же кнопка, но с призывом доработать' do
    CrmCard.create!(kind: 'lead', author: agent, lead_event: lead, status: 'needs_rework')

    expect(crm_buttons).to contain_exactly(a_hash_including(text: a_string_including('доработать'),
                                                            callback_data: "wiz:s:crm_lead:#{lead.id}"))
  end

  it 'карточка на модерации — статус и показ карточки в личке' do
    card = CrmCard.create!(kind: 'lead', author: agent, lead_event: lead, status: 'pending_review')

    expect(crm_buttons).to contain_exactly(a_hash_including(text: a_string_including('На модерации'),
                                                            callback_data: "crm_card:#{card.id}:view"))
  end

  it 'выгруженная — номер в CRM на кнопке' do
    CrmCard.create!(kind: 'lead', author: agent, lead_event: lead, status: 'exported', crm_id: '4455')

    expect(crm_buttons.map { |b| b[:text] }).to eq(['🟢 В CRM #4455'])
  end

  it 'закрытый лид с черновиком — мастер не предлагается' do
    CrmCard.create!(kind: 'lead', author: agent, lead_event: lead, status: 'draft')
    lead.update!(current_stage: 'closed_lost')

    expect(crm_buttons).to be_empty
  end

  it 'закрытый лид с выгруженной карточкой — статус остаётся виден' do
    CrmCard.create!(kind: 'lead', author: agent, lead_event: lead, status: 'exported', crm_id: '4455')
    lead.update!(current_stage: 'closed_won')

    expect(crm_buttons.map { |b| b[:text] }).to eq(['🟢 В CRM #4455'])
  end

  it 'лид, пришедший из CRM, кнопки не получает' do
    lead.lead_ref.update_columns(crm_id: '4455')

    expect(crm_buttons).to be_empty
  end

  it 'лид песочницы с карточкой на модерации — виден статус, а не мастер заявки' do
    lead.update!(metadata: { 'sandbox' => true })
    card = CrmCard.create!(kind: 'lead', author: agent, lead_event: lead, sandbox: true, status: 'pending_review')

    expect(crm_buttons).to contain_exactly(a_hash_including(text: a_string_including('На модерации'),
                                                            callback_data: "crm_card:#{card.id}:view"))
  end

  it 'реальному лиду карточка песочницы не привязывается' do
    CrmCard.create!(kind: 'lead', author: agent, lead_event: lead, sandbox: true, status: 'pending_review')

    expect(crm_buttons.map { |b| b[:callback_data] }).to eq(["wiz:s:crm_lead:#{lead.id}"])
  end

  it 'в группе — ни одного поля карточки, только статус' do
    CrmCard.create!(kind: 'lead', author: agent, lead_event: lead, status: 'pending_review',
                    payload: { 'phone' => '79101234567' })

    expect(described_class.new(lead, client: instance_double(Telegram::Client)).keyboard_for_card.to_s)
      .not_to include('9101234567')
  end
end
# rubocop:enable RSpec/DescribeMethod, RSpec/SpecFilePathFormat
