# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::AnomalyNotifier do
  let!(:director) do
    TelegramUser.create!(
      tg_user_id: 20_001, tg_username: 'dir', first_name: 'Dir',
      role: 'director', is_manager: true, status: 'active', dm_chat_id: 20_001
    )
  end
  let!(:director_no_dm) do
    TelegramUser.create!(
      tg_user_id: 20_002, tg_username: 'dir2', first_name: 'Dir2',
      role: 'director', is_manager: true, status: 'active', dm_chat_id: nil
    )
  end

  let(:staff) do
    TelegramUser.create!(
      tg_user_id: 21_001, tg_username: 'nick4man', first_name: 'Николай',
      role: 'agent', is_manager: false, status: 'active'
    )
  end

  let(:tg_client) { instance_double(Telegram::Client, send_message: { 'message_id' => 1 }) }
  before { allow(Telegram::Client).to receive(:new).and_return(tg_client) }

  def anomaly(metric:, value:, baseline:, label: 'существенное', context: {})
    Telegram::WorkBot::AnomalyDetector::Anomaly.new(
      staff: staff, metric: metric, value: value, baseline: baseline,
      deviation_label: label, context: context
    )
  end

  describe '.call' do
    it 'шлёт DM director\'у с dm_chat_id' do
      a = anomaly(metric: :overdue_rate, value: 0.42, baseline: 0.08)
      sent = described_class.call(a)
      expect(sent).to eq(1)
      expect(tg_client).to have_received(:send_message).with(
        a_string_including('@nick4man'),
        hash_including(chat_id: 20_001, parse_mode: 'HTML')
      )
    end

    it 'пропускает director\'а без dm_chat_id' do
      described_class.call(anomaly(metric: :overdue_rate, value: 0.42, baseline: 0.08))
      expect(tg_client).not_to have_received(:send_message).with(anything, hash_including(chat_id: nil))
    end

    it 'возвращает 0 если cascade пустой' do
      TelegramUser.update_all(status: 'inactive')
      sent = described_class.call(anomaly(metric: :overdue_rate, value: 0.42, baseline: 0.08))
      expect(sent).to eq(0)
    end
  end

  describe 'rendering (Russian text contracts)' do
    it 'overdue_rate — содержит title + %% + label' do
      a = anomaly(metric: :overdue_rate, value: 0.42, baseline: 0.08, label: 'существенное')
      described_class.call(a)
      expect(tg_client).to have_received(:send_message).with(
        a_string_matching(/доля просроченных задач существенно выше/),
        anything
      )
      expect(tg_client).to have_received(:send_message).with(
        a_string_matching(/сейчас.*42%/m),
        anything
      )
      expect(tg_client).to have_received(:send_message).with(
        a_string_matching(/в среднем по команде.*8%/m),
        anything
      )
      expect(tg_client).to have_received(:send_message).with(
        a_string_matching(/отклонение от средней.*существенное/m),
        anything
      )
    end

    it 'first_contact_delay_30m_miss — собственный hint' do
      a = anomaly(metric: :first_contact_delay_30m_miss, value: 0.55, baseline: 0.10)
      described_class.call(a)
      expect(tg_client).to have_received(:send_message).with(
        a_string_matching(/доля лидов без первого контакта/),
        anything
      )
    end

    it 'completion_rate_drop — title «выполнение задач»' do
      a = anomaly(metric: :completion_rate_drop, value: 0.50, baseline: 0.90, label: 'существенное')
      described_class.call(a)
      expect(tg_client).to have_received(:send_message).with(
        a_string_matching(/выполнение задач существенно/),
        anything
      )
    end

    it 'не содержит технических терминов («sigma», «z-score», «anomaly», «MAD»)' do
      a = anomaly(metric: :overdue_rate, value: 0.42, baseline: 0.08)
      described_class.call(a)
      expect(tg_client).to have_received(:send_message).with(
        a_string_matching(/\A((?!sigma|z-score|anomaly|MAD|σ).)*\z/m),
        anything
      )
    end

    it 'staff без tg_username — fallback на first_name' do
      staff.update!(tg_username: nil)
      a = anomaly(metric: :overdue_rate, value: 0.42, baseline: 0.08)
      described_class.call(a)
      expect(tg_client).to have_received(:send_message).with(
        a_string_including('Николай'),
        anything
      )
    end

    it 'содержит disclosure про повтор не раньше следующих суток' do
      a = anomaly(metric: :overdue_rate, value: 0.42, baseline: 0.08)
      described_class.call(a)
      expect(tg_client).to have_received(:send_message).with(
        a_string_matching(/Повтор.*не раньше следующих суток/m),
        anything
      )
    end
  end
end
