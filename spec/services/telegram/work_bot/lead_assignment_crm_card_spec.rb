# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable RSpec/DescribeMethod, RSpec/SpecFilePathFormat -- второй аргумент describe группирует
# спеку по фиче (напоминание о карточке CRM), а не по одному методу.
RSpec.describe Telegram::WorkBot::LeadAssignment, 'напоминание о карточке CRM' do
  let(:tg_client) { instance_double(Telegram::Client, send_message: { 'message_id' => 1 }, edit_message_text: true) }
  let(:director) { TelegramUser.create!(tg_user_id: 98_921, tg_username: 'oksana', role: 'director', status: 'active') }
  let(:agent) do
    TelegramUser.create!(tg_user_id: 98_922, tg_username: 'irina', role: 'agent', status: 'active', dm_chat_id: 98_922)
  end
  let(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'new',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1, metadata: { 'name' => 'Анна' })
  end

  it 'назначенному приходит кнопка карточки CRM и объяснение, зачем она' do
    described_class.new(lead, assignee: agent, actor: director, client: tg_client).call

    expect(tg_client).to have_received(:send_message).with(
      a_string_including('карточку CRM'),
      hash_including(chat_id: agent.dm_chat_id,
                     reply_markup: { inline_keyboard: [[{ text: '📋 Карточка CRM',
                                                          callback_data: "wiz:s:crm_lead:#{lead.id}" }]] })
    )
  end

  it 'лиду, пришедшему из CRM, кнопка не нужна' do
    lead.lead_ref.update_columns(crm_id: '4455')

    described_class.new(lead, assignee: agent, actor: director, client: tg_client).call

    expect(tg_client).to have_received(:send_message).with(anything, hash_not_including(:reply_markup))
  end
end
# rubocop:enable RSpec/DescribeMethod, RSpec/SpecFilePathFormat
