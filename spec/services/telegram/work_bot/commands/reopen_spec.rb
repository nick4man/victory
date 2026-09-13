# frozen_string_literal: true

require 'rails_helper'

# `/reopen <id>` — откат ошибочного /done или /cancel. Окно 24 ч (REOPEN_WINDOW)
# и сохранение first_acked_at — те самые «исключения из общего правила», которые
# по TESTING.md обязаны быть зафиксированы тестом с объяснением «почему»,
# иначе следующий рефакторинг их снимет.
RSpec.describe Telegram::WorkBot::Commands::Reopen do
  let(:sent) { [] }
  let(:dms) { [] }
  let(:tg_client) do
    client = instance_double(Telegram::Client)
    allow(client).to receive(:send_message) do |text, **opts|
      (opts[:reply_to_message_id] ? sent : dms) << text
      { 'message_id' => 1 }
    end
    client
  end

  let!(:agent) do
    TelegramUser.create!(tg_user_id: 96_201, tg_username: 'irina', first_name: 'Ирина',
                         role: 'agent', is_manager: false, status: 'active', dm_chat_id: 96_201)
  end
  let!(:stranger) do
    TelegramUser.create!(tg_user_id: 96_202, tg_username: 'petr', first_name: 'Пётр',
                         role: 'agent', is_manager: false, status: 'active', dm_chat_id: 96_202)
  end
  let!(:manager) do
    TelegramUser.create!(tg_user_id: 96_203, tg_username: 'oks', first_name: 'Оксана',
                         role: 'director', is_manager: true, status: 'active', dm_chat_id: 96_203)
  end

  let!(:task) do
    ::Task.create!(assignee: agent, title: 'Собрать документы', status: 'done',
                   kind: 'document', priority: 'normal',
                   assigned_at: 3.hours.ago, completed_at: 1.hour.ago,
                   first_acked_at: 2.hours.ago, acked_method: 'command',
                   suspicious_flag: true, due_at: 1.day.from_now)
  end

  before { allow(DispatcherDigestRefreshJob).to receive(:perform_async) }

  def run(args, user: agent)
    msg = { 'message_id' => 9, 'from' => { 'id' => user.tg_user_id },
            'chat' => { 'id' => user.tg_user_id, 'type' => 'private' },
            'text' => "/reopen #{args}" }
    described_class.new(message: msg, args: args, tg_user: user, client: tg_client).call
  end

  describe 'happy path' do
    it 'возвращает задачу в работу и снимает следы закрытия' do
      run(task.id.to_s)
      task.reload
      expect(task).to be_status_open
      expect(task.completed_at).to be_nil
      expect(task.acked_method).to be_nil
      expect(task).not_to be_suspicious_flag
    end

    it 'сохраняет first_acked_at — запись «работа была начата» не стирается' do
      expect { run(task.id.to_s) }.not_to(change { task.reload.first_acked_at })
    end

    it 'в ответе называет прежний статус' do
      run(task.id.to_s)
      expect(sent.join).to include('done')
    end
  end

  describe 'окно 24 часа' do
    it 'отказывает, если задача закрыта раньше окна, и предлагает создать новую' do
      task.update!(completed_at: 25.hours.ago)
      run(task.id.to_s)
      expect(task.reload).to be_status_done
      expect(sent.join).to include('/task')
    end

    it 'внутри окна переоткрывает' do
      task.update!(completed_at: 23.hours.ago)
      run(task.id.to_s)
      expect(task.reload).to be_status_open
    end

    # У отменённой задачи completed_at пуст — граница считается по updated_at.
    it 'для canceled считает окно по updated_at' do
      task.update!(status: 'canceled', completed_at: nil)
      run(task.id.to_s)
      expect(task.reload).to be_status_open
    end
  end

  describe 'авторизация и уведомления' do
    it 'чужой агент переоткрыть не может' do
      run(task.id.to_s, user: stranger)
      expect(task.reload).to be_status_done
      expect(sent.join).to include('🚫')
    end

    it 'руководитель переоткрывает чужую и assignee получает DM' do
      run(task.id.to_s, user: manager)
      expect(task.reload).to be_status_open
      expect(dms.join).to include('снова в работе')
    end

    it 'себе самому DM не шлёт' do
      run(task.id.to_s, user: agent)
      expect(dms).to be_empty
    end
  end

  describe 'границы' do
    it 'открытая задача — no-op с дружелюбным ответом' do
      task.update!(status: 'open', completed_at: nil)
      run(task.id.to_s)
      expect(sent.join).to include('и так в работе')
    end

    it 'без id отвечает подсказкой по формату' do
      run('')
      expect(sent.join).to include('/reopen 42')
    end

    it 'на несуществующий id отвечает «не найдена»' do
      run('999999')
      expect(sent.join).to include('не найдена')
    end
  end
end
