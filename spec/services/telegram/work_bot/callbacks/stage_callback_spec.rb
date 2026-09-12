# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Callbacks::StageCallback do
  let(:tg_client) do
    instance_double(Telegram::Client,
                    send_message: { 'message_id' => 77 },
                    edit_message_text: { 'message_id' => 9000 },
                    answer_callback_query: { 'ok' => true })
  end
  let(:agent) { TelegramUser.create!(tg_user_id: 111, role: 'agent', first_name: 'A', is_manager: false, status: 'active') }
  let!(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'tg_dm', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_123, anchor_thread_id: 17,
                      anchor_message_id: 9000, assigned_to: agent)
  end

  def run(data, user: agent)
    cb = { 'id' => 'cb-1', 'data' => data, 'from' => { 'id' => user.tg_user_id },
           'message' => { 'message_id' => 9000, 'message_thread_id' => 17,
                          'chat' => { 'id' => -100_123, 'type' => 'supergroup' } } }
    described_class.new(callback_query: cb, tg_user: user, args: data.split(':').drop(1), client: tg_client).call
  end

  it '📅 Показ → стадия show, first_show_at, и нудж про сегмент в тот же топик' do
    run("stage:#{lead.id}:show")
    lead.reload
    expect(lead.current_stage).to eq('show')
    expect(lead.first_show_at).to be_present
    expect(tg_client).to have_received(:send_message).with(
      a_string_including('сегмент'),
      hash_including(chat_id: -100_123, message_thread_id: 17, reply_markup: hash_including(:inline_keyboard))
    )
  end

  describe 'фильтр «кто едет» (тёмный код)' do
    before { lead.update!(segment: 'cold') }

    it 'при выключенном флаге рекомендации нет' do
      stub_const('ENV', ENV.to_h.except('SHOW_ROUTING_ENABLED'))
      run("stage:#{lead.id}:show")
      expect(tg_client).not_to have_received(:send_message).with(a_string_including('Рекомендация'), anything)
    end

    it 'при включённом флаге приходит рекомендация с кнопками show_assign' do
      stub_const('ENV', ENV.to_h.merge('SHOW_ROUTING_ENABLED' => 'true'))
      run("stage:#{lead.id}:show")
      expect(tg_client).to have_received(:send_message).with(
        a_string_including('Рекомендация'),
        hash_including(reply_markup: hash_including(:inline_keyboard))
      )
    end
  end

  it 'нуджа нет, если сегмент уже указан' do
    lead.update!(segment: 'cash')
    run("stage:#{lead.id}:show")
    expect(tg_client).not_to have_received(:send_message).with(a_string_including('сегмент'), anything)
  end

  it '✍️ Договор → contract + contract_at' do
    run("stage:#{lead.id}:contract")
    expect(lead.reload.current_stage).to eq('contract')
    expect(lead.contract_at).to be_present
  end

  it 'стадия вне разрешённых кнопок → alert' do
    run("stage:#{lead.id}:closed_won")
    expect(lead.reload.current_stage).to eq('first_contact')
    expect(tg_client).to have_received(:answer_callback_query).with('cb-1', hash_including(show_alert: true))
  end

  it 'чужой агент → alert' do
    other = TelegramUser.create!(tg_user_id: 222, role: 'agent', first_name: 'B', is_manager: false, status: 'active')
    run("stage:#{lead.id}:show", user: other)
    expect(lead.reload.current_stage).to eq('first_contact')
  end
end
