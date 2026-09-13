# frozen_string_literal: true

require 'rails_helper'

# Кнопки [▶ В работе] и [✅ Выполнено] в DM-карточке задачи. Путь параллельный
# командам /done и /cancel — и по TESTING.md проверять надо именно согласованность
# двух потребителей одного состояния, а не каждого в изоляции: кнопка и команда
# обязаны приводить задачу в одно и то же состояние, отличаясь только acked_method.
RSpec.describe Telegram::WorkBot::Callbacks::TaskActionCallback do
  let(:acks) { [] }
  let(:tg_client) do
    client = instance_double(Telegram::Client)
    allow(client).to receive(:answer_callback_query) do |_id, text: nil, show_alert: false|
      acks << { text: text, alert: show_alert }
      { 'ok' => true }
    end
    client
  end

  let!(:agent) do
    TelegramUser.create!(tg_user_id: 97_001, tg_username: 'irina', first_name: 'Ирина',
                         role: 'agent', is_manager: false, status: 'active', dm_chat_id: 97_001)
  end
  let!(:stranger) do
    TelegramUser.create!(tg_user_id: 97_002, tg_username: 'petr', first_name: 'Пётр',
                         role: 'agent', is_manager: false, status: 'active', dm_chat_id: 97_002)
  end
  let!(:manager) do
    TelegramUser.create!(tg_user_id: 97_003, tg_username: 'oks', first_name: 'Оксана',
                         role: 'director', is_manager: true, status: 'active', dm_chat_id: 97_003)
  end

  let!(:task) do
    ::Task.create!(assignee: agent, title: 'Показ в 18:00', status: 'open',
                   kind: 'show', priority: 'normal',
                   assigned_at: 2.hours.ago, due_at: 1.day.from_now)
  end

  before { allow(DispatcherDigestRefreshJob).to receive(:perform_async) }

  def run(data, user: agent)
    cb = { 'id' => 'cb-1', 'data' => data, 'from' => { 'id' => user.tg_user_id },
           'message' => { 'message_id' => 500, 'chat' => { 'id' => user.dm_chat_id, 'type' => 'private' } } }
    described_class.new(callback_query: cb, tg_user: user, args: data.split(':').drop(1),
                        client: tg_client).call
  end

  describe 'done' do
    it 'закрывает задачу и отличается от /done только способом подтверждения' do
      run("task:#{task.id}:done")
      task.reload
      expect(task).to be_status_done
      expect(task.acked_method).to eq('button')
      expect(task.completed_at).to be_present
    end

    it 'на повторное нажатие не переписывает completed_at' do
      run("task:#{task.id}:done")
      first = task.reload.completed_at

      run("task:#{task.id}:done")
      expect(task.reload.completed_at).to eq(first)
      expect(acks.last[:text]).to include('Уже выполнено')
    end

    it 'кнопку всегда «отпускает» — ack приходит на каждый клик' do
      run("task:#{task.id}:done")
      expect(acks.size).to eq(1)
    end
  end

  describe 'start' do
    it 'ставит started_at и first_acked_at, не закрывая задачу' do
      run("task:#{task.id}:start")
      task.reload
      expect(task).to be_status_open
      expect(task.started_at).to be_present
      expect(task.first_acked_at).to be_present
    end

    it 'повторный старт не сдвигает started_at' do
      run("task:#{task.id}:start")
      first = task.reload.started_at
      run("task:#{task.id}:start")
      expect(task.reload.started_at).to eq(first)
    end
  end

  describe 'авторизация' do
    it 'чужой сотрудник получает модальный отказ, состояние не меняется' do
      run("task:#{task.id}:done", user: stranger)
      expect(task.reload).to be_status_open
      expect(acks.last).to include(alert: true)
      expect(acks.last[:text]).to include('не твоя задача')
    end

    it 'руководитель может закрыть чужую' do
      run("task:#{task.id}:done", user: manager)
      expect(task.reload).to be_status_done
    end
  end

  describe 'мусорные данные' do
    it 'несуществующая задача — алерт вместо исключения' do
      expect { run('task:999999:done') }.not_to raise_error
      expect(acks.last[:text]).to include('не найдена')
    end

    it 'неизвестное действие — алерт' do
      run("task:#{task.id}:frobnicate")
      expect(task.reload).to be_status_open
      expect(acks.last[:text]).to include('Неизвестное действие')
    end
  end
end
