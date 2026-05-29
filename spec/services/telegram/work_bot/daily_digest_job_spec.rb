# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::DailyDigestJob do
  let!(:director_with_dm) do
    TelegramUser.create!(tg_user_id: 100_001, tg_username: 'dir1', first_name: 'Dir1',
                         role: 'director', is_manager: true, status: 'active', dm_chat_id: 100_001)
  end
  let!(:director_no_dm) do
    TelegramUser.create!(tg_user_id: 100_002, tg_username: 'dir2', first_name: 'Dir2',
                         role: 'director', is_manager: true, status: 'active', dm_chat_id: nil)
  end
  let!(:_agent) do
    TelegramUser.create!(tg_user_id: 100_003, tg_username: 'ag', first_name: 'Ag',
                         role: 'agent', is_manager: false, status: 'active', dm_chat_id: 100_003)
  end

  let(:tg_client) { instance_double(Telegram::Client, send_message: { 'message_id' => 1 }) }

  before { allow(Telegram::Client).to receive(:new).and_return(tg_client) }

  # Phase 15.5 — DailyDigestJob теперь композирует SummarizeGroupMessages.
  # Stub'аем чтобы spec не дёргал real LLM на каждом run.
  before do
    allow(::ChatTools::Staff::SummarizeGroupMessages).to receive(:call).and_return(
      { summary: '📌 Stub summary content', model: 'stub', count: 5 }
    )
  end

  describe '#perform' do
    it 'шлёт digest только директорам с dm_chat_id' do
      travel_to(Time.zone.local(2026, 5, 22, 10, 0)) do # не quiet hours
        described_class.new.perform
      end
      # director_with_dm получает; director_no_dm пропускается
      expect(tg_client).to have_received(:send_message).once.with(
        a_string_matching(/Доброе утро/),
        hash_including(chat_id: 100_001, parse_mode: 'HTML', reply_markup: a_hash_including(:inline_keyboard))
      )
    end

    it 'не шлёт в quiet hours (21:00–08:00 MSK)' do
      travel_to(Time.zone.local(2026, 5, 22, 23, 0)) do # 23:00 = quiet
        result = described_class.new.perform
        expect(result).to eq(:quiet_hours)
      end
      expect(tg_client).not_to have_received(:send_message)
    end

    it 'agent не получает (только role=director)' do
      travel_to(Time.zone.local(2026, 5, 22, 10, 0)) do
        described_class.new.perform
      end
      expect(tg_client).not_to have_received(:send_message).with(anything, hash_including(chat_id: 100_003))
    end

    # Phase 15.5 — LLM-summary в digest
    it 'включает 💬 секцию с LLM-summary вчерашних обсуждений' do
      travel_to(Time.zone.local(2026, 5, 22, 10, 0)) do
        described_class.new.perform
      end
      expect(tg_client).to have_received(:send_message).with(
        a_string_matching(/Обсуждалось в рабочем чате.*Stub summary/m),
        hash_including(chat_id: 100_001)
      )
      expect(::ChatTools::Staff::SummarizeGroupMessages).to have_received(:call).with(
        hash_including(period: 'yesterday'), hash_including(asked_by: director_with_dm)
      )
    end

    it 'graceful fail — digest шлётся даже если SummarizeGroupMessages вернул error' do
      allow(::ChatTools::Staff::SummarizeGroupMessages).to receive(:call).and_return(
        { error: 'tool_failed', message: 'LLM down' }
      )
      travel_to(Time.zone.local(2026, 5, 22, 10, 0)) do
        described_class.new.perform
      end
      # Digest всё равно ушёл, просто без секции «Обсуждалось»
      expect(tg_client).to have_received(:send_message).with(
        a_string_matching(/Доброе утро/), hash_including(chat_id: 100_001)
      )
    end
  end
end
