# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Kpi::AgencyDigestJob do
  let!(:director) do
    TelegramUser.create!(tg_user_id: 100_001, tg_username: 'dir1', first_name: 'Dir1',
                         role: 'director', is_manager: true, status: 'active', dm_chat_id: 100_001)
  end
  let!(:admin) do
    TelegramUser.create!(tg_user_id: 100_002, tg_username: 'adm', first_name: 'Adm',
                         role: 'admin', is_manager: true, status: 'active', dm_chat_id: 100_002)
  end

  let(:tg_client) { instance_double(Telegram::Client) }

  before do
    allow(Telegram::Client).to receive(:new).and_return(tg_client)
    allow(Kpi::AgencyDigest).to receive(:new)
      .and_return(instance_double(Kpi::AgencyDigest, build_text: 'digest'))
  end

  describe '#perform' do
    it 'не падает, если часть отправок не удалась' do
      call = 0
      allow(tg_client).to receive(:send_message) do
        call += 1
        raise Telegram::Client::Error, 'boom' if call == 1

        { 'message_id' => 1 }
      end

      expect { described_class.new.perform }.not_to raise_error
    end

    it 'падает, если дайджест не ушёл ни одному получателю (сеть лежит) — Sidekiq retry' do
      allow(tg_client).to receive(:send_message)
        .and_raise(Telegram::Client::Error, 'Telegram sendMessage: network error')

      expect { described_class.new.perform }
        .to raise_error(/agency digest not delivered: 2\/2 sends failed/)
    end
  end
end
