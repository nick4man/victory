# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Commands::Assign do
  let!(:director) do
    TelegramUser.create!(tg_user_id: 95_001, tg_username: 'oks', first_name: 'Оксана',
                         role: 'director', is_manager: true, status: 'active', dm_chat_id: 95_001)
  end
  let!(:agent) do
    TelegramUser.create!(tg_user_id: 95_002, tg_username: 'irina', first_name: 'Ирина',
                         role: 'agent', is_manager: false, status: 'active', dm_chat_id: 95_002)
  end

  let(:lead_ref) do
    User.find_or_create_by!(email: "lead-#{SecureRandom.hex(4)}@stub.local") do |u|
      u.password = SecureRandom.urlsafe_base64(20)
      u.first_name = 'Lead'; u.last_name = 'Stub'; u.role = :client; u.active = true
    end
  end

  let!(:lead) do
    LeadEvent.create!(
      lead_ref: lead_ref, source: 'site_form', current_stage: 'new',
      anchor_topic_key: 'apartments', tg_chat_id: -1_003_779_115_845,
      anchor_message_id: 555,
      metadata: { 'name' => 'Клиент' }
    )
  end

  let(:tg_client) { instance_double(Telegram::Client, send_message: { 'message_id' => 1 }, edit_message_text: { 'message_id' => 1 }) }

  before { allow_any_instance_of(Telegram::WorkBot::LeadAssignment).to receive(:call).and_return(double(success?: true, error_message: nil)) }

  describe 'Phase 15 — DM mode (explicit lead_id)' do
    let(:dm_message) do
      {
        'message_id' => 1, 'from' => { 'id' => director.tg_user_id },
        'chat' => { 'id' => director.tg_user_id, 'type' => 'private' },
        'text' => "/assign #{lead.id} @irina"
      }
    end

    it 'resolve_lead! по lead_id из args + assignee по @username' do
      handler = described_class.new(message: dm_message, args: "#{lead.id} @irina", tg_user: director, client: tg_client)
      handler.call
      expect(tg_client).to have_received(:send_message).with(a_string_matching(/Лид ##{lead.id} → /), hash_including(:chat_id))
    end
  end

  describe 'legacy — reply-to-anchor mode (group)' do
    let(:group_message_reply) do
      {
        'message_id' => 1, 'from' => { 'id' => director.tg_user_id },
        'chat' => { 'id' => -1_003_779_115_845, 'type' => 'supergroup' },
        'message_thread_id' => 17,
        'reply_to_message' => { 'message_id' => 555 },
        'text' => '/assign @irina'
      }
    end

    it 'находит лид через reply-to-anchor когда нет lead_id в args' do
      handler = described_class.new(message: group_message_reply, args: '@irina', tg_user: director, client: tg_client)
      handler.call
      expect(tg_client).to have_received(:send_message).with(a_string_matching(/Лид ##{lead.id}/), hash_including(:chat_id))
    end
  end

  describe 'нет лида ни в args ни в reply' do
    let(:dm_no_lead) do
      {
        'message_id' => 1, 'from' => { 'id' => director.tg_user_id },
        'chat' => { 'id' => director.tg_user_id, 'type' => 'private' },
        'text' => '/assign @irina'
      }
    end

    it 'возвращает hint про lead_id' do
      handler = described_class.new(message: dm_no_lead, args: '@irina', tg_user: director, client: tg_client)
      handler.call
      expect(tg_client).to have_received(:send_message).with(a_string_matching(/Лид не найден.*lead_id/m), hash_including(:chat_id))
    end
  end

  # Phase 15 polish — picker для DM `/assign <lead_id>` без username
  describe 'Phase 15 polish — picker mode (DM /assign <lead_id>)' do
    before do
      # сделать assignable хотя бы 1 staff
      TelegramUser.create!(tg_user_id: 95_010, tg_username: 'masha', first_name: 'Маша',
                           role: 'agent', is_manager: false, status: 'active',
                           assignable: true, dm_chat_id: 95_010)
    end

    let(:dm_picker_msg) do
      {
        'message_id' => 1, 'from' => { 'id' => director.tg_user_id },
        'chat' => { 'id' => director.tg_user_id, 'type' => 'private' },
        'text' => "/assign #{lead.id}"
      }
    end

    it 'показывает inline-picker (assign_to кнопки) когда username пустой после lead_id' do
      handler = described_class.new(message: dm_picker_msg, args: lead.id.to_s, tg_user: director, client: tg_client)
      handler.call

      expect(tg_client).to have_received(:send_message).with(
        a_string_matching(/Кому назначить лид ##{lead.id}/),
        hash_including(reply_markup: a_hash_including(:inline_keyboard))
      )
    end

    it 'callback_data содержит assign_to:<lead_id>:<user_id> для каждой кнопки' do
      handler = described_class.new(message: dm_picker_msg, args: lead.id.to_s, tg_user: director, client: tg_client)
      handler.call

      expect(tg_client).to have_received(:send_message) do |_text, **kwargs|
        callbacks = kwargs[:reply_markup][:inline_keyboard].flatten.map { |b| b[:callback_data] }
        expect(callbacks.any? { |c| c.start_with?("assign_to:#{lead.id}:") }).to be(true)
        expect(callbacks).to include("assign_cancel:#{lead.id}")
      end
    end
  end
end
