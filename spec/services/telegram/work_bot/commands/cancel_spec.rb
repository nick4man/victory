# frozen_string_literal: true

require 'rails_helper'

# `/cancel <id> [причина]`. Отличие от /done принципиальное для KPI: canceled
# НЕ входит в tasks_completed. Спеки не было — а перепутать две ветки легко,
# они почти близнецы.
RSpec.describe Telegram::WorkBot::Commands::Cancel do
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
    TelegramUser.create!(tg_user_id: 96_101, tg_username: 'irina', first_name: 'Ирина',
                         role: 'agent', is_manager: false, status: 'active', dm_chat_id: 96_101)
  end
  let!(:stranger) do
    TelegramUser.create!(tg_user_id: 96_102, tg_username: 'petr', first_name: 'Пётр',
                         role: 'agent', is_manager: false, status: 'active', dm_chat_id: 96_102)
  end
  let!(:manager) do
    TelegramUser.create!(tg_user_id: 96_103, tg_username: 'oks', first_name: 'Оксана',
                         role: 'director', is_manager: true, status: 'active', dm_chat_id: 96_103)
  end

  let!(:task) do
    ::Task.create!(assignee: agent, title: 'Свозить на показ', status: 'open',
                   kind: 'show', priority: 'normal',
                   assigned_at: 2.hours.ago, due_at: 1.day.from_now)
  end

  before { allow(DispatcherDigestRefreshJob).to receive(:perform_async) }

  def run(args, user: agent)
    msg = { 'message_id' => 7, 'from' => { 'id' => user.tg_user_id },
            'chat' => { 'id' => user.tg_user_id, 'type' => 'private' },
            'text' => "/cancel #{args}" }
    described_class.new(message: msg, args: args, tg_user: user, client: tg_client).call
  end

  it 'переводит задачу в canceled, а не в done' do
    run(task.id.to_s)
    task.reload
    expect(task).to be_status_canceled
    expect(task.completed_at).to be_nil
    expect(task.acked_method).to be_nil
  end

  it 'причина попадает в ответ и экранируется' do
    run("#{task.id} клиент <передумал>")
    expect(sent.join).to include('&lt;передумал&gt;')
    expect(sent.join).not_to include('<передумал>')
  end

  describe 'авторизация' do
    it 'чужой агент отменить не может' do
      run(task.id.to_s, user: stranger)
      expect(task.reload).to be_status_open
      expect(sent.join).to include('🚫')
    end

    it 'руководитель отменяет любую' do
      run(task.id.to_s, user: manager)
      expect(task.reload).to be_status_canceled
    end
  end

  describe 'границы' do
    it 'выполненную задачу отменить нельзя — предлагает создать новую' do
      task.update!(status: 'done', completed_at: Time.current)
      run(task.id.to_s)
      expect(task.reload).to be_status_done
      expect(sent.join).to include('/task')
    end

    it 'повторная отмена — дружелюбное сообщение, без смены состояния' do
      task.update!(status: 'canceled')
      expect { run(task.id.to_s) }.not_to(change { task.reload.updated_at })
      expect(sent.join).to include('уже отменена')
    end

    it 'без id отвечает подсказкой по формату' do
      run('')
      expect(sent.join).to include('/cancel 42')
    end

    it 'на несуществующий id отвечает «не найдена»' do
      run('999999')
      expect(sent.join).to include('не найдена')
    end
  end
end
