# frozen_string_literal: true

require 'rails_helper'

# 🔴 ВНИМАНИЕ: часть примеров ниже КРАСНАЯ на текущем main — и это находка,
# а не поломка спеки.
#
# Commands::Reassign#handle вызывает `new_assignee.status_active?`, но у
# TelegramUser нет такого предиката: `status` там — обычная строковая колонка
# с `validates :status, inclusion:`, enum только у `role`. Идиома перенесена с
# модели Task, где `status` действительно enum с `prefix: true`.
#
# Следствие: любой успешный путь /reassign падает в NoMethodError, его глотает
# rescue в Commands::Base, пользователь получает «⚠️ Ошибка: undefined method…»,
# а в BotCommandLog ложится result='error'. Команда не работала ни разу с момента
# появления (Phase 11 Iter 23) — именно потому, что спеки на неё не было.
#
# Фикс: `new_assignee.status == 'active'` (или завести enum :status в модели —
# но это заденет STATUSES, scope :active и валидацию, это отдельное решение).
RSpec.describe Telegram::WorkBot::Commands::Reassign do
  let(:sent) { [] }
  let(:dms) { [] }
  let(:tg_client) do
    client = instance_double(Telegram::Client)
    allow(client).to receive(:send_message) do |text, **opts|
      (opts[:reply_to_message_id] ? sent : dms) << text
      { 'message_id' => 1 }
    end
    allow(client).to receive(:edit_message_reply_markup).and_return({ 'message_id' => 1 })
    client
  end

  let!(:manager) do
    TelegramUser.create!(tg_user_id: 96_301, tg_username: 'oks', first_name: 'Оксана',
                         role: 'director', is_manager: true, status: 'active', dm_chat_id: 96_301)
  end
  let!(:prev_assignee) do
    TelegramUser.create!(tg_user_id: 96_302, tg_username: 'irina', first_name: 'Ирина',
                         role: 'agent', is_manager: false, status: 'active', dm_chat_id: 96_302)
  end
  let!(:new_assignee) do
    TelegramUser.create!(tg_user_id: 96_303, tg_username: 'petr', first_name: 'Пётр',
                         role: 'agent', is_manager: false, status: 'active', dm_chat_id: 96_303)
  end

  let!(:task) do
    ::Task.create!(assignee: prev_assignee, title: 'Позвонить собственнику', status: 'open',
                   kind: 'call', priority: 'normal',
                   assigned_at: 2.hours.ago, notified_at: 1.hour.ago,
                   tg_message_id: 4242, due_at: 1.day.from_now)
  end

  before do
    allow(DispatcherDigestRefreshJob).to receive(:perform_async)
    allow_any_instance_of(Telegram::WorkBot::TaskDispatcher).to receive(:call).and_return(true)
  end

  def run(args, user: manager)
    msg = { 'message_id' => 11, 'from' => { 'id' => user.tg_user_id },
            'chat' => { 'id' => user.tg_user_id, 'type' => 'private' },
            'text' => "/reassign #{args}" }
    described_class.new(message: msg, args: args, tg_user: user, client: tg_client).call
  end

  describe 'happy path' do
    it 'переводит задачу на нового ответственного' do
      run("#{task.id} @petr")
      expect(task.reload.assignee_id).to eq(new_assignee.id)
    end

    it 'сбрасывает notified_at и tg_message_id — новому нужна свежая карточка' do
      run("#{task.id} @petr")
      task.reload
      expect(task.notified_at).to be_nil
      expect(task.tg_message_id).to be_nil
    end

    it 'снимает кнопки со старой DM-карточки прежнего ответственного' do
      run("#{task.id} @petr")
      expect(tg_client).to have_received(:edit_message_reply_markup).with(
        chat_id: prev_assignee.dm_chat_id, message_id: 4242, reply_markup: { inline_keyboard: [] }
      )
    end

    it 'уведомляет прежнего ответственного в личку' do
      run("#{task.id} @petr")
      expect(dms.join).to include('Задача передана')
    end

    it 'в ответе показывает переход «кто → кому»' do
      run("#{task.id} @petr")
      expect(sent.join).to include('@irina').and include('@petr')
    end
  end

  describe 'права' do
    it 'агенту команда недоступна — перебрасывать задачи без санкции нельзя' do
      run("#{task.id} @petr", user: prev_assignee)
      expect(task.reload.assignee_id).to eq(prev_assignee.id)
      expect(sent.join).to include('руководителям')
    end
  end

  describe 'границы' do
    it 'закрытую задачу не передаёт — отправляет в /reopen' do
      task.update!(status: 'done', completed_at: Time.current)
      run("#{task.id} @petr")
      expect(task.reload.assignee_id).to eq(prev_assignee.id)
      expect(sent.join).to include('/reopen')
    end

    it 'на того же исполнителя — no-op' do
      run("#{task.id} @irina")
      expect(sent.join).to include('уже назначена')
      expect(task.reload.notified_at).to be_present
    end

    it 'неизвестный @username — «не найден», задача не тронута' do
      run("#{task.id} @nobody")
      expect(task.reload.assignee_id).to eq(prev_assignee.id)
      expect(sent.join).to include('не найден')
    end

    it 'неактивный сотрудник назначения не получает' do
      new_assignee.update!(status: 'inactive')
      run("#{task.id} @petr")
      expect(task.reload.assignee_id).to eq(prev_assignee.id)
      expect(sent.join).to include('🚫')
    end

    it 'сотрудник с assignable=false назначения не получает' do
      new_assignee.update!(assignable: false)
      run("#{task.id} @petr")
      expect(task.reload.assignee_id).to eq(prev_assignee.id)
      expect(sent.join).to include('🚫')
    end

    it 'без @username отвечает подсказкой по формату' do
      run(task.id.to_s)
      expect(sent.join).to include('/reassign 42 @username')
    end

    it 'на несуществующий id отвечает «не найдена»' do
      run('999999 @petr')
      expect(sent.join).to include('не найдена')
    end
  end
end
