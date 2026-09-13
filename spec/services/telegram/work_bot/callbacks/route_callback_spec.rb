# frozen_string_literal: true

require 'rails_helper'

# Кнопки маршрутизации (КВАРТИРЫ / ДОМА / … / ОЦЕНКА) под якорной карточкой
# в #ДИСПЕТЧЕРСКОЙ. Сам перенос делает AnchorMigrator — у него своя зона
# ответственности; здесь проверяется только контракт колбэка: валидация ключа,
# проброс в мигратор и то, что кнопка в любом исходе «отпускается».
RSpec.describe Telegram::WorkBot::Callbacks::RouteCallback do
  let(:acks) { [] }
  let(:tg_client) do
    client = instance_double(Telegram::Client)
    allow(client).to receive(:answer_callback_query) do |_id, text: nil, show_alert: false|
      acks << { text: text, alert: show_alert }
      { 'ok' => true }
    end
    client
  end

  let!(:manager) do
    TelegramUser.create!(tg_user_id: 97_101, tg_username: 'oks', first_name: 'Оксана',
                         role: 'manager', is_manager: true, status: 'active', dm_chat_id: 97_101)
  end
  let!(:agent) do
    TelegramUser.create!(tg_user_id: 97_102, tg_username: 'irina', first_name: 'Ирина',
                         role: 'agent', is_manager: false, status: 'active', dm_chat_id: 97_102)
  end

  let!(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'new',
                      anchor_topic_key: 'dispatcher', tg_chat_id: -1_003_779_115_845,
                      anchor_thread_id: 1, anchor_message_id: 600)
  end

  let(:migrator) { instance_double(Telegram::WorkBot::AnchorMigrator, call: true) }

  before { allow(Telegram::WorkBot::AnchorMigrator).to receive(:new).and_return(migrator) }

  def run(data, user: manager)
    cb = { 'id' => 'cb-2', 'data' => data, 'from' => { 'id' => user.tg_user_id },
           'message' => { 'message_id' => 600, 'message_thread_id' => 1,
                          'chat' => { 'id' => -1_003_779_115_845, 'type' => 'supergroup' } } }
    described_class.new(callback_query: cb, tg_user: user, args: data.split(':').drop(1),
                        client: tg_client).call
  end

  it 'передаёт лид и целевой топик в AnchorMigrator, автора — как actor' do
    run("route:#{lead.id}:apartments")
    expect(Telegram::WorkBot::AnchorMigrator)
      .to have_received(:new).with(lead, 'apartments', actor: manager, client: tg_client)
  end

  it 'на успешный перенос отвечает названием топика без алерта' do
    run("route:#{lead.id}:apartments")
    expect(acks.last[:alert]).to be(false)
    expect(acks.last[:text]).to include(Telegram::TopicRegistry.title('apartments').to_s)
  end

  it 'неизвестный ключ топика отсекает до мигратора' do
    run("route:#{lead.id}:atlantis")
    expect(Telegram::WorkBot::AnchorMigrator).not_to have_received(:new)
    expect(acks.last).to include(alert: true)
  end

  it 'отказ мигратора виден пользователю алертом, а не тишиной' do
    allow(migrator).to receive(:call).and_return(false)
    run("route:#{lead.id}:apartments")
    expect(acks.last).to include(alert: true)
  end

  it 'агенту маршрутизация недоступна' do
    run("route:#{lead.id}:apartments", user: agent)
    expect(Telegram::WorkBot::AnchorMigrator).not_to have_received(:new)
    expect(acks.last[:text]).to include('руководителей')
  end

  # ⚠️ Фиксация ТЕКУЩЕГО поведения, а не желаемого.
  #
  # Commands::Base после Phase 13 Iter 41 пускает по manager-гейту ещё и
  # директоров/админов (manager_or_director?) — ровно потому, что директор с
  # is_manager=false блокировался от /assign и /route. Callbacks::Base этот фикс
  # не получил: там по-прежнему голый `tg_user.is_manager?`. То есть команда
  # /route такому директору доступна, а кнопка под той же карточкой — нет.
  #
  # Пример намеренно зелёный: когда асимметрию решат убрать, он покраснеет и
  # заставит принять решение осознанно, а не молча.
  it 'директор без is_manager кнопкой воспользоваться НЕ может (асимметрия с командами)' do
    director = TelegramUser.create!(tg_user_id: 97_103, tg_username: 'dir', first_name: 'Директор',
                                    role: 'director', is_manager: false, status: 'active',
                                    dm_chat_id: 97_103)
    expect(director.manager_or_director?).to be(true)

    run("route:#{lead.id}:apartments", user: director)
    expect(Telegram::WorkBot::AnchorMigrator).not_to have_received(:new)
    expect(acks.last[:text]).to include('руководителей')
  end
end
