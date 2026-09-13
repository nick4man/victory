# frozen_string_literal: true

require 'rails_helper'

# Кнопка [👤 Назначить] под якорной карточкой: бот постит picker-сообщение со
# списком сотрудников. Ключевая деталь — id этого сообщения сохраняется в
# metadata['assign_picker_message_id']; без него AssignCancelCallback и
# AssignToCallback не смогут его убрать, и picker останется висеть в топике.
RSpec.describe Telegram::WorkBot::Callbacks::AssignCallback do
  let(:acks) { [] }
  let(:posts) { [] }
  let(:tg_client) do
    client = instance_double(Telegram::Client)
    allow(client).to receive(:answer_callback_query) do |_id, text: nil, show_alert: false|
      acks << { text: text, alert: show_alert }
      { 'ok' => true }
    end
    allow(client).to receive(:send_message) do |text, **opts|
      posts << { text: text, opts: opts }
      { 'message_id' => 7007 }
    end
    client
  end

  let!(:manager) do
    TelegramUser.create!(tg_user_id: 97_201, tg_username: 'oks', first_name: 'Оксана',
                         role: 'manager', is_manager: true, status: 'active', dm_chat_id: 97_201)
  end
  let!(:current_assignee) do
    TelegramUser.create!(tg_user_id: 97_202, tg_username: 'irina', first_name: 'Ирина',
                         role: 'agent', is_manager: false, status: 'active', dm_chat_id: 97_202)
  end
  let!(:free_agent) do
    TelegramUser.create!(tg_user_id: 97_203, tg_username: 'petr', first_name: 'Пётр',
                         role: 'agent', is_manager: false, status: 'active', dm_chat_id: 97_203)
  end

  let!(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'new',
                      anchor_topic_key: 'apartments', tg_chat_id: -1_003_779_115_845,
                      anchor_thread_id: 17, anchor_message_id: 700,
                      assigned_to: current_assignee)
  end

  def run(user: manager)
    cb = { 'id' => 'cb-3', 'data' => "assign:#{lead.id}", 'from' => { 'id' => user.tg_user_id },
           'message' => { 'message_id' => 700, 'message_thread_id' => 17,
                          'chat' => { 'id' => -1_003_779_115_845, 'type' => 'supergroup' } } }
    described_class.new(callback_query: cb, tg_user: user, args: [lead.id.to_s],
                        client: tg_client).call
  end

  # Последняя строка клавиатуры — [✖️ Отмена]; в списке кандидатов ей не место,
  # иначе её callback_data («assign_cancel:<lead_id>») подмешивается в id сотрудников.
  def picker_buttons
    posts.last[:opts][:reply_markup][:inline_keyboard][0..-2].flatten
  end

  def picker_user_ids
    picker_buttons.map { |b| b[:callback_data].split(':').last }
  end

  it 'постит picker в тот же топик, где нажали кнопку' do
    run
    expect(posts.last[:opts]).to include(chat_id: -1_003_779_115_845, message_thread_id: 17)
  end

  it 'запоминает message_id picker-сообщения — иначе его нечем будет убрать' do
    run
    expect(lead.reload.metadata['assign_picker_message_id']).to eq(7007)
  end

  it 'не предлагает назначить на того, на ком лид уже висит' do
    run
    data = picker_buttons.map { |b| b[:callback_data] }
    expect(data).not_to include("assign_to:#{lead.id}:#{current_assignee.id}")
    expect(data).to include("assign_to:#{lead.id}:#{free_agent.id}")
  end

  it 'последней кнопкой всегда даёт отмену' do
    expect { run }.to change { posts.size }.by(1)
    expect(posts.last[:opts][:reply_markup][:inline_keyboard].last)
      .to eq([{ text: '✖️ Отмена', callback_data: "assign_cancel:#{lead.id}" }])
  end

  it 'не предлагает неактивных и не-assignable сотрудников' do
    free_agent.update!(assignable: false)
    other = TelegramUser.create!(tg_user_id: 97_204, tg_username: 'ivan', first_name: 'Иван',
                                 role: 'agent', is_manager: false, status: 'inactive')
    run
    expect(picker_user_ids).not_to include(free_agent.id.to_s, other.id.to_s)
  end

  it 'когда назначать некого — алерт, а не пустой picker' do
    free_agent.update!(assignable: false)
    manager.update!(assignable: false)
    run
    expect(posts).to be_empty
    expect(acks.last).to include(alert: true)
  end

  it 'агенту кнопка недоступна' do
    run(user: free_agent)
    expect(posts).to be_empty
    expect(acks.last[:text]).to include('руководителей')
  end

  # Iter 57 follow-up: сотрудник без tg_username (приватный профиль) не должен
  # проваливаться в NULL-сортировку и утягивать список — он идёт в конец.
  it 'сотрудника без username ставит в конец списка, а не теряет' do
    nameless = TelegramUser.create!(tg_user_id: 97_205, tg_username: nil, first_name: 'Надежда',
                                    role: 'agent', is_manager: false, status: 'active')
    run
    expect(picker_user_ids).to include(nameless.id.to_s)
    expect(picker_user_ids.last).to eq(nameless.id.to_s)
  end
end
