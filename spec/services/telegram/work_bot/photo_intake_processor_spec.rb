# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::PhotoIntakeProcessor do
  let!(:director) do
    TelegramUser.create!(tg_user_id: 11_001, tg_username: 'oks07victory', first_name: 'Оксана',
                         role: 'director', is_manager: true, status: 'active', dm_chat_id: 11_001)
  end
  let!(:agent) do
    TelegramUser.create!(tg_user_id: 11_002, tg_username: 'irina', first_name: 'Ирина',
                         role: 'agent', is_manager: false, status: 'active', dm_chat_id: 11_002)
  end

  let(:photo_payload) do
    [
      { 'file_id' => 'AgACFile1', 'file_unique_id' => 'u1', 'width' => 100, 'height' => 100 },
      { 'file_id' => 'AgACFile2', 'file_unique_id' => 'u2', 'width' => 800, 'height' => 600 }
    ]
  end

  let(:director_dm_photo) do
    {
      'message_id' => 1,
      'from' => { 'id' => director.tg_user_id, 'username' => director.tg_username, 'is_bot' => false },
      'chat' => { 'id' => director.tg_user_id, 'type' => 'private' },
      'photo' => photo_payload
    }
  end

  let(:agent_dm_photo) do
    director_dm_photo.merge(
      'from' => { 'id' => agent.tg_user_id, 'username' => agent.tg_username, 'is_bot' => false },
      'chat' => { 'id' => agent.tg_user_id, 'type' => 'private' }
    )
  end

  describe '.applies?' do
    it 'true для photo в DM от manager/director' do
      expect(described_class.applies?(director_dm_photo)).to be(true)
    end

    it 'false для photo в DM от agent' do
      expect(described_class.applies?(agent_dm_photo)).to be(false)
    end

    it 'false для группового photo' do
      group_msg = director_dm_photo.merge('chat' => { 'id' => -100123, 'type' => 'supergroup' })
      expect(described_class.applies?(group_msg)).to be(false)
    end

    it 'false для не-photo сообщения' do
      text_msg = director_dm_photo.dup.tap { |m| m.delete('photo') }.merge('text' => 'hi')
      expect(described_class.applies?(text_msg)).to be(false)
    end

    it 'false для inactive manager' do
      director.update!(status: 'inactive')
      expect(described_class.applies?(director_dm_photo)).to be(false)
    end

    it 'false для бота' do
      bot_msg = director_dm_photo.merge('from' => director_dm_photo['from'].merge('is_bot' => true))
      expect(described_class.applies?(bot_msg)).to be(false)
    end
  end

  describe '#call' do
    let(:tg_client) { instance_double(Telegram::Client) }

    before do
      allow(tg_client).to receive(:send_message).and_return({ 'message_id' => 100 })
    end

    it 'сохраняет pending_action и отправляет prompt с inline-кнопками' do
      described_class.new(director_dm_photo, client: tg_client).call

      pa = director.reload.pending_action
      expect(pa).to be_present
      expect(pa['type']).to eq('photo_disposition')
      expect(pa['step']).to eq('choose_destination')
      expect(pa['data']['file_id']).to eq('AgACFile2') # последний (largest)

      expect(tg_client).to have_received(:send_message) do |_text, **kwargs|
        markup = kwargs[:reply_markup]
        callbacks = markup[:inline_keyboard].flatten.map { |b| b[:callback_data] }
        # Iter 61 — 4 кнопки: cloud / share (NEW без задачи) / task (renamed) / cancel
        expect(callbacks).to include('photo:dispose:cloud',
                                     'photo:dispose:share',
                                     'photo:dispose:task',
                                     'photo:dispose:cancel')
      end
    end

    it 'возвращает :awaiting_disposition' do
      result = described_class.new(director_dm_photo, client: tg_client).call
      expect(result).to eq(:awaiting_disposition)
    end

    it 'TTL pending_action ~10 минут' do
      described_class.new(director_dm_photo, client: tg_client).call
      pa = director.reload.pending_action
      expires = Time.iso8601(pa['expires_at'])
      expect(expires).to be_within(30.seconds).of(10.minutes.from_now)
    end
  end
end
