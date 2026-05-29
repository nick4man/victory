# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::ClientBot::ActivationRequestProcessor do
  let(:tg_user_id) { 600_111_222 }
  let(:tg_client)  { instance_double(Telegram::Client, send_message: { 'message_id' => 1 }) }

  before { allow(Telegram::Client).to receive(:new).and_return(tg_client) }

  def build_start(text: '/start', chat_type: 'private', from_id: tg_user_id, username: nil)
    {
      'chat' => { 'id' => from_id, 'type' => chat_type },
      'from' => { 'id' => from_id, 'username' => username },
      'text' => text
    }
  end

  def build_contact(phone:, from_id: tg_user_id, contact_user_id: nil, chat_type: 'private')
    {
      'chat' => { 'id' => from_id, 'type' => chat_type },
      'from' => { 'id' => from_id, 'username' => 'tester' },
      'contact' => { 'phone_number' => phone, 'user_id' => contact_user_id || from_id }
    }
  end

  # ------------------------------------------------------------------
  # .applies?
  # ------------------------------------------------------------------
  describe '.applies?' do
    it 'matches bare /start в private chat' do
      expect(described_class.applies?(build_start)).to be(true)
    end

    it 'rejects /start с token payload (LinkProcessor responsibility)' do
      msg = build_start(text: '/start sometokenpayloadXYZ')
      expect(described_class.applies?(msg)).to be(false)
    end

    it 'matches contact-share в private chat' do
      msg = build_contact(phone: '+79991234567')
      expect(described_class.applies?(msg)).to be(true)
    end

    it 'rejects group chats' do
      expect(described_class.applies?(build_start(chat_type: 'group'))).to be(false)
    end

    it 'rejects messages from staff (TelegramUser)' do
      staff_id = 777_777_777
      TelegramUser.create!(tg_user_id: staff_id, role: 'agent',
                           first_name: 'Staff', last_name: 'X',
                           is_manager: false)
      expect(described_class.applies?(build_start(from_id: staff_id))).to be(false)
    end

    it 'rejects non-/start non-contact messages' do
      msg = build_start(text: 'привет, хочу квартиру')
      expect(described_class.applies?(msg)).to be(false)
    end
  end

  # ------------------------------------------------------------------
  # Stage A — /start без token
  # ------------------------------------------------------------------
  describe '.call — Stage A (/start без token)' do
    it 'replies с request_contact reply_markup' do
      described_class.call(build_start)
      expect(tg_client).to have_received(:send_message)
        .with(
          a_string_including('поделитесь номером'),
          hash_including(
            chat_id: tg_user_id,
            reply_markup: hash_including(
              keyboard: [[{ text: 'Подтвердить телефон', request_contact: true }]]
            )
          )
        )
    end

    it 'returns :handled' do
      expect(described_class.call(build_start)).to eq(:handled)
    end
  end

  # ------------------------------------------------------------------
  # Stage B — message.contact
  # ------------------------------------------------------------------
  describe '.call — Stage B (contact match found)' do
    let!(:user) { create(:user, phone: '+79991234567', invited_at: nil) }

    it 'links user with tg_user_id и tg_username' do
      msg = build_contact(phone: '+79991234567')
      msg['from']['username'] = 'someone'
      described_class.call(msg)
      expect(user.reload.tg_user_id).to eq(tg_user_id)
      expect(user.tg_username).to eq('someone')
      expect(user.tg_linked_at).to be_within(2.seconds).of(Time.current)
      expect(user.invited_at).to be_within(2.seconds).of(Time.current)
    end

    it 'replies с web-cabinet auto-login URL' do
      described_class.call(build_contact(phone: '+79991234567'))
      expect(tg_client).to have_received(:send_message)
        .with(
          a_string_including('Привязали ваш Telegram', '/cabinet/verify/'),
          hash_including(chat_id: tg_user_id)
        )
    end

    it 'creates MagicLinkToken scope=login' do
      expect { described_class.call(build_contact(phone: '+79991234567')) }
        .to change { MagicLinkToken.where(scope: 'login').count }.by(1)
    end
  end

  describe '.call — Stage B (no match)' do
    it 'replies без User changes' do
      described_class.call(build_contact(phone: '+79009990000'))
      expect(tg_client).to have_received(:send_message)
        .with(a_string_including('Не нашли вас'), anything)
    end
  end

  describe '.call — Stage B (security: contact user_id mismatch)' do
    let!(:user) { create(:user, phone: '+79991234567') }

    it 'refuses to link when contact.user_id != from.id' do
      msg = build_contact(phone: '+79991234567', contact_user_id: 999_999_999)
      described_class.call(msg)
      expect(tg_client).to have_received(:send_message)
        .with(a_string_including('Контакт другого человека'), anything)
      expect(user.reload.tg_user_id).to be_nil
    end
  end

  describe '.call — Stage B (PhoneStopList block)' do
    let!(:user) { create(:user, phone: '+79991234567') }

    before { PhoneStopList.add!(phone: '+79991234567', reason: 'spam complaint') }

    it 'refuses with stop-list message' do
      described_class.call(build_contact(phone: '+79991234567'))
      expect(tg_client).to have_received(:send_message)
        .with(a_string_including('исключён из коммуникаций'), anything)
      expect(user.reload.tg_user_id).to be_nil
    end
  end

  describe '.call — Stage B (tg_user_id already taken)' do
    let!(:user)  { create(:user, phone: '+79991234567') }
    let!(:other) { create(:user, :tg_linked, tg_user_id: tg_user_id) }

    it 'replies appropriately + does NOT link target user' do
      described_class.call(build_contact(phone: '+79991234567'))
      expect(tg_client).to have_received(:send_message)
        .with(a_string_including('уже привязан к другому'), anything)
      expect(user.reload.tg_user_id).to be_nil
    end
  end
end
