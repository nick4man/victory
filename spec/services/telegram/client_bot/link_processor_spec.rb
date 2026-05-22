# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::ClientBot::LinkProcessor do
  let(:user)       { create(:user) }
  let(:tok)        { TgLinkToken.generate!(user: user) }
  let(:tg_user_id) { 555_111_222 }
  let(:tg_client)  { instance_double(Telegram::Client, send_message: { 'message_id' => 1 }) }

  before { allow(Telegram::Client).to receive(:new).and_return(tg_client) }

  def build_msg(text:, chat_type: 'private', from_id: tg_user_id, username: 'johndoe')
    {
      'chat' => { 'id' => from_id, 'type' => chat_type },
      'from' => { 'id' => from_id, 'username' => username },
      'text' => text
    }
  end

  describe '.applies?' do
    it 'matches /start with token payload в private chat' do
      msg = build_msg(text: "/start #{tok.token}")
      expect(described_class.applies?(msg)).to be(true)
    end

    it 'rejects /start without payload' do
      msg = build_msg(text: '/start')
      expect(described_class.applies?(msg)).to be(false)
    end

    it 'rejects group chats' do
      msg = build_msg(text: "/start #{tok.token}", chat_type: 'group')
      expect(described_class.applies?(msg)).to be(false)
    end

    it 'rejects messages from staff (TelegramUser)' do
      staff_id = 777_777_777
      TelegramUser.create!(tg_user_id: staff_id, role: 'agent',
                           first_name: 'Staff', last_name: 'Member',
                           is_manager: false)
      msg = build_msg(text: "/start #{tok.token}", from_id: staff_id)
      expect(described_class.applies?(msg)).to be(false)
    end

    it 'rejects non-/start text' do
      msg = build_msg(text: 'привет, расскажите про квартиру')
      expect(described_class.applies?(msg)).to be(false)
    end
  end

  describe '.call (happy path)' do
    it 'links the user with tg_user_id and username' do
      described_class.call(build_msg(text: "/start #{tok.token}"))
      expect(user.reload.tg_user_id).to eq(tg_user_id)
      expect(user.tg_username).to eq('johndoe')
    end

    it 'replies with success message' do
      described_class.call(build_msg(text: "/start #{tok.token}"))
      expect(tg_client).to have_received(:send_message)
        .with(a_string_including('Telegram подключён'), hash_including(chat_id: tg_user_id))
    end

    it 'returns :handled' do
      expect(described_class.call(build_msg(text: "/start #{tok.token}"))).to eq(:handled)
    end

    it 'marks token consumed' do
      described_class.call(build_msg(text: "/start #{tok.token}"))
      expect(tok.reload).to be_consumed
    end
  end

  describe '.call (error paths)' do
    it 'replies with :not_found message for invalid token' do
      described_class.call(build_msg(text: '/start bogus_token_does_not_exist'))
      expect(tg_client).to have_received(:send_message)
        .with(a_string_including('Ссылка не распознана'), hash_including(chat_id: tg_user_id))
    end

    it 'replies with :expired message for expired token' do
      expired = create(:tg_link_token, :expired, user: user)
      described_class.call(build_msg(text: "/start #{expired.token}"))
      expect(tg_client).to have_received(:send_message)
        .with(a_string_including('устарела'), hash_including(chat_id: tg_user_id))
      expect(user.reload.tg_user_id).to be_nil
    end

    it 'replies with :already_consumed message for re-used token' do
      described_class.call(build_msg(text: "/start #{tok.token}"))
      # Reset mock count + second attempt
      described_class.call(build_msg(text: "/start #{tok.token}"))
      expect(tg_client).to have_received(:send_message)
        .with(a_string_including('уже использована'), anything)
    end

    it 'replies with :tg_user_already_linked_to_other when tg taken' do
      other_user = create(:user, :tg_linked, tg_user_id: tg_user_id)
      described_class.call(build_msg(text: "/start #{tok.token}"))
      expect(tg_client).to have_received(:send_message)
        .with(a_string_including('уже привязан к другому аккаунту'), anything)
      expect(other_user.reload.tg_user_id).to eq(tg_user_id) # untouched
    end
  end
end
