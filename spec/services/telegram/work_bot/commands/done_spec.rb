# frozen_string_literal: true

require 'rails_helper'

# `/done <id>` — один из трёх путей закрытия задачи (ещё кнопка [✅] и
# ✅-реакция). Спеки не было вообще, хотя команда меняет KPI-показатели:
# status=done попадает в tasks_completed, а suspicious_flag — в weekly review.
RSpec.describe Telegram::WorkBot::Commands::Done do
  let(:sent) { [] }
  let(:tg_client) do
    client = instance_double(Telegram::Client)
    allow(client).to receive(:send_message) do |text, **_opts|
      sent << text
      { 'message_id' => 1 }
    end
    client
  end

  let!(:agent) do
    TelegramUser.create!(tg_user_id: 96_001, tg_username: 'irina', first_name: 'Ирина',
                         role: 'agent', is_manager: false, status: 'active', dm_chat_id: 96_001)
  end
  let!(:stranger) do
    TelegramUser.create!(tg_user_id: 96_002, tg_username: 'petr', first_name: 'Пётр',
                         role: 'agent', is_manager: false, status: 'active', dm_chat_id: 96_002)
  end
  let!(:manager) do
    TelegramUser.create!(tg_user_id: 96_003, tg_username: 'oks', first_name: 'Оксана',
                         role: 'director', is_manager: true, status: 'active', dm_chat_id: 96_003)
  end

  # assigned_at в прошлом — иначе Task#suspicious_completion? пометит закрытие
  # подозрительным (окно 60 с), и это перепутает happy path с примером про флаг.
  let!(:task) do
    ::Task.create!(assignee: agent, created_by: manager, title: 'Позвонить клиенту',
                   status: 'open', kind: 'other', priority: 'normal',
                   assigned_at: 2.hours.ago, due_at: 1.day.from_now)
  end

  # Task#after_commit дёргает Sidekiq-джобу напрямую (не ActiveJob), то есть
  # мимо queue_adapter=:test — стабим, чтобы спека не зависела от Redis.
  before { allow(DispatcherDigestRefreshJob).to receive(:perform_async) }

  def run(args, user: agent)
    msg = { 'message_id' => 5, 'from' => { 'id' => user.tg_user_id },
            'chat' => { 'id' => user.tg_user_id, 'type' => 'private' },
            'text' => "/done #{args}" }
    described_class.new(message: msg, args: args, tg_user: user, client: tg_client).call
  end

  describe 'happy path' do
    it 'закрывает задачу и помечает способ подтверждения как command' do
      run(task.id.to_s)
      task.reload
      expect(task).to be_status_done
      expect(task.completed_at).to be_present
      expect(task.acked_method).to eq('command')
      expect(sent.join).to include("##{task.id}")
    end

    it 'ставит first_acked_at, если его ещё не было' do
      expect { run(task.id.to_s) }.to change { task.reload.first_acked_at }.from(nil)
    end

    it 'пишет строку в BotCommandLog — команда попадает в единый поток аудита' do
      expect { run(task.id.to_s) }.to change(BotCommandLog, :count).by(1)
      expect(BotCommandLog.last.command).to eq('/done')
    end
  end

  describe 'авторизация' do
    it 'чужой агент не может закрыть задачу' do
      run(task.id.to_s, user: stranger)
      expect(task.reload).to be_status_open
      expect(sent.join).to include('🚫')
    end

    it 'руководитель закрывает чужую задачу (override)' do
      run(task.id.to_s, user: manager)
      expect(task.reload).to be_status_done
    end
  end

  describe 'границы' do
    it 'повторный /done не переписывает completed_at' do
      run(task.id.to_s)
      first_completed_at = task.reload.completed_at

      sent.clear
      run(task.id.to_s)

      expect(task.reload.completed_at).to eq(first_completed_at)
      expect(sent.join).to include('уже выполнена')
    end

    it 'отменённую задачу закрыть нельзя' do
      task.update!(status: 'canceled')
      run(task.id.to_s)
      expect(task.reload).to be_status_canceled
      expect(sent.join).to include('отменена')
    end

    it 'без аргумента отвечает подсказкой по формату' do
      run('')
      expect(sent.join).to include('/done 42')
    end

    it 'на несуществующий id отвечает «не найдена», а не падает' do
      expect { run('999999') }.not_to raise_error
      expect(sent.join).to include('не найдена')
    end
  end

  describe 'suspicious_flag' do
    # Закрытие быстрее SUSPICIOUS_WINDOW (60 с) от назначения — surface-only
    # сигнал для weekly review. Пользователь должен увидеть его в ответе,
    # иначе флаг всплывёт только в отчёте, когда объясняться уже поздно.
    let!(:fresh_task) do
      ::Task.create!(assignee: agent, title: 'Только что назначена', status: 'open',
                     kind: 'other', priority: 'normal', assigned_at: Time.current)
    end

    it 'предупреждает в ответе, когда закрытие подозрительно быстрое' do
      run(fresh_task.id.to_s)
      expect(fresh_task.reload).to be_suspicious_flag
      expect(sent.join).to include('suspicious')
    end
  end
end
