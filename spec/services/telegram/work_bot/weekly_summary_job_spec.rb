# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::WeeklySummaryJob do
  let!(:director) do
    TelegramUser.create!(tg_user_id: 110_001, tg_username: 'dir', first_name: 'Dir',
                         role: 'director', is_manager: true, status: 'active', dm_chat_id: 110_001)
  end
  let(:tg_client) { instance_double(Telegram::Client, send_message: { 'message_id' => 1 }) }

  before { allow(Telegram::Client).to receive(:new).and_return(tg_client) }

  describe '#perform' do
    it 'шлёт недельный отчёт director\'ам с dm_chat_id' do
      described_class.new.perform
      expect(tg_client).to have_received(:send_message).with(
        # Заголовок переименован в «📊 Сводка за неделю · дд.мм–дд.мм.гг».
        a_string_matching(/Сводка за неделю/),
        hash_including(chat_id: 110_001, parse_mode: 'HTML', reply_markup: a_hash_including(:inline_keyboard))
      )
    end

    # BOTTLENECK — блок воронки показов в той же сводке, что уже приходит.
    it 'содержит блок показов с подтверждённым отчётом за прошлую неделю' do
      agent = TelegramUser.create!(tg_user_id: 110_002, first_name: 'Ag', role: 'agent', status: 'active')
      lead = LeadEvent.create!(lead_ref: create(:inquiry), source: 'tg_dm', current_stage: 'show',
                               anchor_topic_key: 'apartments', tg_chat_id: -100_1, assigned_to: agent,
                               segment: 'cold', first_show_at: 2.days.ago)
      ShowReport.create!(lead_event: lead, conducted_by: agent, reported_by: agent, conducted_at: 2.days.ago,
                         source: 'voice', status: 'confirmed', objections: ['кухня'])

      described_class.new.perform
      expect(tg_client).to have_received(:send_message).with(
        a_string_including('Показы за неделю: 1'), anything
      )
    end

    it 'возвращает :done' do
      expect(described_class.new.perform).to eq(:done)
    end
  end
end
