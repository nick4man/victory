# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::AnomalyDetectorJob do
  let!(:director) do
    TelegramUser.create!(
      tg_user_id: 30_001, tg_username: 'dir', first_name: 'Dir',
      role: 'director', is_manager: true, status: 'active', dm_chat_id: 30_001
    )
  end

  let(:staff) do
    TelegramUser.create!(
      tg_user_id: 30_002, tg_username: 'nick', first_name: 'Ник',
      role: 'agent', is_manager: false, status: 'active'
    )
  end

  let(:fake_anomaly) do
    Telegram::WorkBot::AnomalyDetector::Anomaly.new(
      staff: staff, metric: :overdue_rate, value: 0.42, baseline: 0.08,
      deviation_label: 'существенное', context: { open_tasks: 10 }
    )
  end

  let(:tg_client) { instance_double(Telegram::Client, send_message: { 'message_id' => 1 }) }
  before { allow(Telegram::Client).to receive(:new).and_return(tg_client) }

  describe '#perform' do
    before do
      allow(Telegram::WorkBot::AnomalyDetector).to receive(:run).and_return([fake_anomaly])
    end

    it 'не запускает в quiet hours (23:00 MSK)' do
      travel_to(Time.zone.local(2026, 5, 29, 23, 0)) do
        result = described_class.new.perform
        expect(result).to eq(:quiet_hours)
      end
      expect(Telegram::WorkBot::AnomalyDetector).not_to have_received(:run)
    end

    it 'детектит, шлёт DM, логирует counts' do
      allow(Telegram::AlertThrottle).to receive(:allow?).and_return(true)

      travel_to(Time.zone.local(2026, 5, 29, 10, 0)) do
        described_class.new.perform
      end

      expect(Telegram::WorkBot::AnomalyDetector).to have_received(:run)
      expect(tg_client).to have_received(:send_message).with(
        a_string_including('@nick'),
        hash_including(chat_id: 30_001)
      )
    end

    it 'idempotent — повторный запуск в тот же день не шлёт DM (throttled)' do
      # Первый запуск — throttle разрешает
      allow(Telegram::AlertThrottle).to receive(:allow?).and_return(true, false)

      travel_to(Time.zone.local(2026, 5, 29, 10, 0)) do
        described_class.new.perform
        described_class.new.perform
      end

      # Только один send_message
      expect(tg_client).to have_received(:send_message).once
    end

    it 'передаёт throttle key с правильным форматом «anomaly:STAFF_ID:METRIC:DATE»' do
      allow(Telegram::AlertThrottle).to receive(:allow?).and_return(true)

      travel_to(Time.zone.local(2026, 5, 29, 10, 0)) do
        described_class.new.perform
      end

      expect(Telegram::AlertThrottle).to have_received(:allow?).with(
        key: "anomaly:#{staff.id}:overdue_rate:2026-05-29",
        ttl: 24.hours
      )
    end

    it 'возвращает :done после обработки' do
      allow(Telegram::AlertThrottle).to receive(:allow?).and_return(true)
      travel_to(Time.zone.local(2026, 5, 29, 10, 0)) do
        expect(described_class.new.perform).to eq(:done)
      end
    end

    it 'обрабатывает empty anomalies (no signal)' do
      allow(Telegram::WorkBot::AnomalyDetector).to receive(:run).and_return([])

      travel_to(Time.zone.local(2026, 5, 29, 10, 0)) do
        described_class.new.perform
      end

      expect(tg_client).not_to have_received(:send_message)
    end

    it 'не падает если notifier бросает — продолжает обработку других anomalies' do
      other_anomaly = Telegram::WorkBot::AnomalyDetector::Anomaly.new(
        staff: staff, metric: :first_contact_delay_30m_miss, value: 0.55, baseline: 0.10,
        deviation_label: 'значительное', context: {}
      )
      allow(Telegram::WorkBot::AnomalyDetector).to receive(:run).and_return([fake_anomaly, other_anomaly])
      allow(Telegram::AlertThrottle).to receive(:allow?).and_return(true)
      allow(Telegram::WorkBot::AnomalyNotifier).to receive(:call).and_raise(StandardError, 'boom')

      travel_to(Time.zone.local(2026, 5, 29, 10, 0)) do
        expect { described_class.new.perform }.not_to raise_error
      end

      # Вызвался для обеих anomalies (вторая не прервалась)
      expect(Telegram::WorkBot::AnomalyNotifier).to have_received(:call).twice
    end
  end
end
