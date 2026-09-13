# frozen_string_literal: true

require 'rails_helper'

# `/task` — единственный ручной способ завести задачу по лиду. Без спеки
# оставались обе развилки сразу: dual-context resolve_lead! (reply в группе vs
# lead_id первым аргументом в DM) и разбор даты в формате dd.MM.yy.
RSpec.describe Telegram::WorkBot::Commands::Task do
  let(:sent) { [] }
  let(:tg_client) do
    client = instance_double(Telegram::Client)
    allow(client).to receive(:send_message) do |text, **_opts|
      sent << text
      { 'message_id' => 1 }
    end
    client
  end

  let!(:manager) do
    TelegramUser.create!(tg_user_id: 96_401, tg_username: 'oks', first_name: 'Оксана',
                         role: 'director', is_manager: true, status: 'active', dm_chat_id: 96_401)
  end
  let!(:agent) do
    TelegramUser.create!(tg_user_id: 96_402, tg_username: 'irina', first_name: 'Ирина',
                         role: 'agent', is_manager: false, status: 'active', dm_chat_id: 96_402)
  end

  let!(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'new',
                      anchor_topic_key: 'apartments', tg_chat_id: -1_003_779_115_845,
                      anchor_thread_id: 17, anchor_message_id: 555, assigned_to: agent)
  end

  before { allow(DispatcherDigestRefreshJob).to receive(:perform_async) }

  def run(args, message:)
    described_class.new(message: message, args: args, tg_user: manager, client: tg_client).call
  end

  def group_message(text)
    { 'message_id' => 21, 'from' => { 'id' => manager.tg_user_id },
      'chat' => { 'id' => -1_003_779_115_845, 'type' => 'supergroup' },
      'message_thread_id' => 17,
      'reply_to_message' => { 'message_id' => 555 },
      'text' => text }
  end

  def dm_message(text)
    { 'message_id' => 22, 'from' => { 'id' => manager.tg_user_id },
      'chat' => { 'id' => manager.tg_user_id, 'type' => 'private' }, 'text' => text }
  end

  describe 'group-режим — reply на якорь' do
    it 'создаёт задачу с дедлайном на конец указанного дня' do
      expect { run('15.05.26 позвонить по ипотеке', message: group_message('/task …')) }
        .to change(::Task, :count).by(1)

      created = ::Task.order(:id).last
      expect(created.lead_event_id).to eq(lead.id)
      expect(created.title).to eq('позвонить по ипотеке')
      # Конец дня, а не полночь: задача «на 15.05» не должна протухнуть в 00:00.
      expect(created.due_at.to_date).to eq(Date.new(2026, 5, 15))
      expect(created.due_at.hour).to eq(23)
    end

    it 'назначает задачу ответственному по лиду, а не автору команды' do
      run('15.05.26 текст', message: group_message('/task …'))
      expect(::Task.order(:id).last.assignee_id).to eq(agent.id)
      expect(::Task.order(:id).last.created_by_id).to eq(manager.id)
    end

    it 'без ответственного по лиду задача остаётся на авторе' do
      lead.update!(assigned_to: nil)
      run('15.05.26 текст', message: group_message('/task …'))
      expect(::Task.order(:id).last.assignee_id).to eq(manager.id)
    end
  end

  describe 'DM-режим — lead_id первым аргументом' do
    it 'выкусывает lead_id из аргументов и не считает его частью даты' do
      run("#{lead.id} 15.05.26 подготовить договор", message: dm_message('/task …'))
      created = ::Task.order(:id).last
      expect(created.lead_event_id).to eq(lead.id)
      expect(created.title).to eq('подготовить договор')
    end
  end

  describe 'разбор даты' do
    it 'принимает короткую запись без ведущих нулей' do
      run('5.5.26 текст', message: group_message('/task …'))
      expect(::Task.order(:id).last.due_at.to_date).to eq(Date.new(2026, 5, 5))
    end

    it 'на нераспознанную дату не создаёт задачу и объясняет формат' do
      expect { run('2026-05-15 текст', message: group_message('/task …')) }
        .not_to change(::Task, :count)
      expect(sent.join).to include('dd.MM.yy')
    end
  end

  describe 'границы' do
    it 'без лида (ни reply, ни lead_id) отвечает подсказкой' do
      expect { run('15.05.26 текст', message: dm_message('/task …')) }
        .not_to change(::Task, :count)
      expect(sent.join).to include('Лид не найден')
    end

    it 'без текста задачи не создаёт её' do
      expect { run('15.05.26', message: group_message('/task …')) }
        .not_to change(::Task, :count)
      expect(sent.join).to include('Формат')
    end

    it 'не ходит в CRM, когда у лида нет crm_id' do
      expect(Topnlab::Client).not_to receive(:new)
      run('15.05.26 текст', message: group_message('/task …'))
    end
  end
end
