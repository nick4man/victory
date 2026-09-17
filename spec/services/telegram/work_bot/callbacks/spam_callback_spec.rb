# frozen_string_literal: true

require 'rails_helper'

# [🚫 Спам] — единственная деструктивная кнопка под якорной карточкой: сносит
# все три сообщения лида в группе и закрывает его как closed_lost. Спеки не
# было, хотя в live-test-playbook она в «красной» группе H.
RSpec.describe Telegram::WorkBot::Callbacks::SpamCallback do
  let(:acks) { [] }
  let(:deleted) { [] }
  let(:tg_client) do
    client = instance_double(Telegram::Client)
    allow(client).to receive(:answer_callback_query) do |_id, text: nil, show_alert: false|
      acks << { text: text, alert: show_alert }
      { 'ok' => true }
    end
    allow(client).to receive(:delete_message) do |chat_id:, message_id:|
      deleted << { chat_id: chat_id, message_id: message_id }
      true
    end
    client
  end

  let!(:manager) do
    TelegramUser.create!(tg_user_id: 97_401, tg_username: 'oks', first_name: 'Оксана',
                         role: 'manager', is_manager: true, status: 'active', dm_chat_id: 97_401)
  end
  let!(:agent) do
    TelegramUser.create!(tg_user_id: 97_402, tg_username: 'irina', first_name: 'Ирина',
                         role: 'agent', is_manager: false, status: 'active', dm_chat_id: 97_402)
  end

  let(:inquiry) { create(:inquiry) }
  let!(:lead) do
    LeadEvent.create!(lead_ref: inquiry, source: 'site_form', current_stage: 'new',
                      anchor_topic_key: 'apartments', tg_chat_id: -1_003_779_115_845,
                      anchor_thread_id: 17, anchor_message_id: 900,
                      dispatcher_message_id: 901, deal_mirror_message_id: 902)
  end

  def run(user: manager)
    cb = { 'id' => 'cb-5', 'data' => "spam:#{lead.id}", 'from' => { 'id' => user.tg_user_id },
           'message' => { 'message_id' => 900, 'message_thread_id' => 17,
                          'chat' => { 'id' => -1_003_779_115_845, 'type' => 'supergroup' } } }
    described_class.new(callback_query: cb, tg_user: user, args: [lead.id.to_s],
                        client: tg_client).call
  end

  describe 'happy path' do
    it 'закрывает лид как closed_lost и проставляет время закрытия' do
      run
      lead.reload
      expect(lead.current_stage).to eq('closed_lost')
      expect(lead.closed_at).to be_present
    end

    it 'сохраняет, кто и когда пометил — без этого решение не оспорить' do
      run
      expect(lead.reload.metadata['spam_marked_by']).to eq('@oks')
      expect(lead.reload.metadata['spam_marked_at']).to be_present
    end

    it 'сносит все три сообщения лида' do
      run
      expect(deleted.map { |d| d[:message_id] }).to contain_exactly(900, 901, 902)
    end

    it 'не удаляет одно и то же сообщение дважды, когда якорь ещё в ДИСПЕТЧЕРСКОЙ' do
      lead.update!(dispatcher_message_id: 900, deal_mirror_message_id: nil)
      run
      expect(deleted.map { |d| d[:message_id] }).to eq([900])
    end

    it 'падение удаления не срывает закрытие лида' do
      allow(tg_client).to receive(:delete_message).and_raise(Telegram::Client::Error, 'message can\'t be deleted')
      run
      expect(lead.reload.current_stage).to eq('closed_lost')
    end
  end

  describe 'идемпотентность' do
    it 'повторный клик не переписывает closed_at и не удаляет ничего заново' do
      run
      first_closed_at = lead.reload.closed_at
      deleted.clear

      run
      expect(lead.reload.closed_at).to eq(first_closed_at)
      expect(deleted).to be_empty
      expect(acks.last[:text]).to include('Уже помечено')
    end
  end

  describe 'CRM' do
    it 'без crm_id в CRM не ходит' do
      expect(Topnlab::Client).not_to receive(:new)
      run
    end

    it 'с crm_id помечает заявку спамом и оставляет ноту' do
      inquiry.update_column(:crm_id, '4242')
      topnlab = instance_double(Topnlab::Client, patch_entity: true, set_note: true)
      allow(Topnlab::Client).to receive(:new).and_return(topnlab)

      run

      expect(topnlab).to have_received(:patch_entity)
        .with(id: 4242, type: 'order', fields: { fc_is_spam: true })
      expect(topnlab).to have_received(:set_note).with(hash_including(id: 4242, type: 'order'))
    end

    it 'отказ CRM не мешает закрыть лид локально' do
      inquiry.update_column(:crm_id, '4242')
      topnlab = instance_double(Topnlab::Client)
      allow(Topnlab::Client).to receive(:new).and_return(topnlab)
      allow(topnlab).to receive(:patch_entity).and_raise(Topnlab::Client::Error, 'CRM 500')
      allow(topnlab).to receive(:set_note).and_raise(Topnlab::Client::Error, 'CRM 500')

      run
      expect(lead.reload.current_stage).to eq('closed_lost')
    end
  end

  describe 'права' do
    it 'агенту деструктивная кнопка недоступна' do
      run(user: agent)
      expect(lead.reload.current_stage).to eq('new')
      expect(deleted).to be_empty
      expect(acks.last[:text]).to include('руководителей')
    end
  end
end
