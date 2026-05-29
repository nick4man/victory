# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::PushToClient do
  let(:user)   { create(:user, :tg_linked) }
  let(:client) { instance_double(Telegram::Client) }

  before { allow(Telegram::Client).to receive(:new).and_return(client) }

  describe '.send (happy path)' do
    before do
      allow(client).to receive(:send_message)
        .and_return({ 'message_id' => 1024, 'chat' => { 'id' => user.tg_user_id }, 'text' => 'ok' })
    end

    it 'returns success result with cost 0' do
      r = described_class.send(user: user, message: 'Привет')
      expect(r.success?).to be(true)
      expect(r.message_id).to eq(1024)
      expect(r.cost).to eq(0.0)
      expect(r.raw).to be_a(Hash)
    end

    it 'sends to user.tg_user_id as chat_id' do
      described_class.send(user: user, message: 'X')
      expect(client).to have_received(:send_message)
        .with('X', hash_including(chat_id: user.tg_user_id))
    end
  end

  describe 'skip cases' do
    it 'skips when user is nil' do
      r = described_class.send(user: nil, message: 'X')
      expect(r.success?).to be(false)
      expect(r.error).to eq('user nil')
    end

    it 'skips when tg_user_id is blank' do
      unlinked = create(:user)
      r = described_class.send(user: unlinked, message: 'X')
      expect(r.success?).to be(false)
      expect(r.error).to eq('tg not linked')
    end

    it 'skips when message is blank' do
      r = described_class.send(user: user, message: '   ')
      expect(r.success?).to be(false)
      expect(r.error).to eq('message blank')
    end
  end

  describe 'error: bot blocked by user' do
    before do
      allow(client).to receive(:send_message)
        .and_raise(Telegram::Client::Error, 'Forbidden: bot was blocked by the user')
    end

    it 'returns failure result' do
      r = described_class.send(user: user, message: 'X')
      expect(r.success?).to be(false)
      expect(r.error).to include('bot was blocked')
    end

    it 'auto-unlinks tg_user_id (so next dispatch falls to SMS)' do
      described_class.send(user: user, message: 'X')
      expect(user.reload.tg_user_id).to be_nil
      expect(user.tg_username).to be_nil
      expect(user.tg_linked_at).to be_nil
    end
  end

  describe 'error: chat not found' do
    before do
      allow(client).to receive(:send_message)
        .and_raise(Telegram::Client::Error, 'Bad Request: chat not found')
    end

    it 'auto-unlinks (user deleted TG account)' do
      described_class.send(user: user, message: 'X')
      expect(user.reload.tg_user_id).to be_nil
    end
  end

  describe 'error: transient network' do
    before do
      allow(client).to receive(:send_message)
        .and_raise(Telegram::Client::Error, 'Network timeout')
    end

    it 'does NOT auto-unlink for transient errors' do
      described_class.send(user: user, message: 'X')
      expect(user.reload.tg_user_id).to eq(user.tg_user_id) # still linked
    end
  end
end
