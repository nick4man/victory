# frozen_string_literal: true

require 'rails_helper'

# Пошаговые мастера: кнопка → вопрос → проверка. Спека гоняет мастер так же,
# как сотрудник: нажатия идут через Callbacks::WizardCallback с настоящим
# callback_data из клавиатуры последнего сообщения, текст — через Engine#text.
# Так ловится расхождение между тем, что нарисовано, и тем, что разбирается.
RSpec.describe Telegram::WorkBot::Wizard::Engine do
  let(:dms) { [] }
  let(:acks) { [] }
  let(:tg_client) do
    client = instance_double(Telegram::Client)
    allow(client).to receive(:send_message) do |text, **opts|
      dms << { text: text, keyboard: opts.dig(:reply_markup, :inline_keyboard) || [], chat_id: opts[:chat_id] }
      { 'message_id' => 1000 + dms.size }
    end
    allow(client).to receive_messages(edit_message_reply_markup: true, edit_message_text: { 'message_id' => 1 })
    allow(client).to receive(:answer_callback_query) { |_id, text: nil, show_alert: false| acks << [text, show_alert] }
    client
  end

  let!(:manager) do
    TelegramUser.create!(tg_user_id: 97_101, tg_username: 'oks', first_name: 'Оксана',
                         role: 'director', is_manager: true, status: 'active', dm_chat_id: 97_101)
  end
  let!(:agent) do
    TelegramUser.create!(tg_user_id: 97_102, tg_username: 'irina', first_name: 'Ирина',
                         role: 'agent', is_manager: false, status: 'active', dm_chat_id: 97_102)
  end
  let!(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'new',
                      anchor_topic_key: 'apartments', tg_chat_id: -1_003_779_115_845,
                      anchor_thread_id: 17, anchor_message_id: 555, assigned_to: agent,
                      metadata: { 'name' => 'Анна Смирнова', 'summary' => 'Есенина 29, 2-комн' })
  end

  before do
    allow(DispatcherDigestRefreshJob).to receive(:perform_async)
  end

  def fmt(date)
    Formatters::DateFormat.fmt(date)
  end

  def engine(user = manager)
    described_class.new(tg_user: user, client: tg_client)
  end

  def last_text
    dms.last[:text]
  end

  # Нажимает кнопку последнего сообщения, чей текст содержит label.
  def press(label, user: manager, chat_type: 'private')
    button = dms.last[:keyboard].flatten.find { |b| b[:text].include?(label) }
    raise "нет кнопки «#{label}» в: #{dms.last[:keyboard].flatten.map { |b| b[:text] }}" unless button

    tap_callback(button[:callback_data], user: user, chat_type: chat_type)
  end

  def tap_callback(data, user: manager, chat_type: 'private')
    cb = { 'id' => 'cb1', 'data' => data, 'from' => { 'id' => user.tg_user_id },
           'message' => { 'message_id' => 1, 'chat' => { 'id' => user.tg_user_id, 'type' => chat_type } } }
    Telegram::WorkBot::Callbacks::WizardCallback.new(callback_query: cb, tg_user: user,
                                                     args: data.split(':').drop(1), client: tg_client).call
  end

  def say(text, user: manager)
    engine(user).text(text)
  end

  def state(user = manager)
    user.reload.pending_action&.dig('data')
  end

  describe 'задача с дедлайном' do
    it 'с карточки: лид уже известен, мастер начинает со срока и создаёт задачу' do
      tap_callback("wiz:s:task:#{lead.id}", chat_type: 'supergroup')
      expect(acks.last.first).to include('личке')
      expect(dms.last[:chat_id]).to eq(manager.dm_chat_id)
      expect(last_text).to include('До какого числа?')

      press('Завтра')
      expect(last_text).to include('Что нужно сделать?')

      say('Собрать документы по ипотеке')
      expect(last_text).to include('На кого ставим?')

      expect { press('ответственный по лиду') }.to change(::Task, :count).by(1)

      task = ::Task.order(:id).last
      expect(task.lead_event_id).to eq(lead.id)
      expect(task.title).to eq('Собрать документы по ипотеке')
      expect(task.assignee_id).to eq(agent.id)
      expect(task.created_by_id).to eq(manager.id)
      expect(task.due_at.to_date).to eq(Date.current + 1)
      expect(last_text).to include("Задача ##{task.id} создана").and include(fmt(Date.current + 1))
      expect(manager.reload.pending_action).to be_nil
    end

    it 'из меню: лид выбирается из списка последних открытых' do
      tap_callback('wiz:s:task')
      expect(last_text).to include('По какому лиду?')

      press("##{lead.id}")
      expect(last_text).to include('До какого числа?')
    end

    it 'ручной ввод номера лида проверяет существование и не сбрасывает шаг' do
      tap_callback('wiz:s:task')
      press('Ввести номер лида')

      say('999999')
      expect(last_text).to include('Лид #999999 не найден').and include('Шаг не сброшен')
      expect(state['step']).to eq('lead')

      say(lead.id.to_s)
      expect(last_text).to include('До какого числа?')
    end

    it 'дата в неверном формате или в прошлом — тот же шаг, с разбором и быстрыми датами' do
      tap_callback("wiz:s:task:#{lead.id}")

      say('2026-09-20')
      expect(last_text).to include('Не понимаю дату').and include('dd.MM.yy')
      expect(dms.last[:keyboard].flatten.map { |b| b[:text] }).to include('Завтра')

      say(fmt(Date.current - 3))
      expect(last_text).to include('Дедлайн в прошлом')
      expect(state['step']).to eq('due')

      say(fmt(Date.current + 7))
      expect(last_text).to include('Что нужно сделать?')
    end

    it 'слишком длинный заголовок не принимается, срок при этом сохранён' do
      tap_callback("wiz:s:task:#{lead.id}")
      press('Завтра')

      say('x' * 300)
      expect(last_text).to include('Слишком длинно: 300')
      expect(state['ctx']['due']).to eq(fmt(Date.current + 1))
    end

    it 'без ответственного по лиду шаг исполнителя пропускается — задача на авторе' do
      lead.update!(assigned_to: nil)
      tap_callback("wiz:s:task:#{lead.id}")
      press('Завтра')

      expect { say('Позвонить') }.to change(::Task, :count).by(1)
      expect(::Task.order(:id).last.assignee_id).to eq(manager.id)
    end

    it '«Назад» возвращает к предыдущему вопросу и забывает ответ на него' do
      tap_callback("wiz:s:task:#{lead.id}")
      press('Завтра')
      press('Назад')

      expect(last_text).to include('До какого числа?')
      expect(state['ctx']).not_to have_key('due')
      # Лид пришёл с карточки, а не был отвечен, — «Назад» его не трогает.
      expect(state['ctx']['lead']).to eq(lead.id.to_s)
    end

    it '«Отмена» снимает состояние, текст после неё в мастер не попадает' do
      tap_callback("wiz:s:task:#{lead.id}")
      press('Отмена')

      expect(last_text).to include('Мастер отменён')
      expect(manager.reload.pending_action).to be_nil
      expect(say('Позвонить')).to be_nil
    end

    it 'кнопка пройденного шага не применяется молча' do
      tap_callback("wiz:s:task:#{lead.id}")
      stale = dms.last[:keyboard].flatten.find { |b| b[:text] == 'Завтра' }[:callback_data]
      press('Завтра')

      expect { tap_callback(stale) }.not_to(change { state['ctx'] })
      expect(acks.last).to eq(['Этот шаг уже неактуален — мастер ушёл дальше, отменён или истёк.', true])
    end

    it 'в текстовый шаг выбора свободный текст не принимается' do
      lead.update!(assigned_to: agent)
      tap_callback("wiz:s:task:#{lead.id}")
      press('Завтра')
      say('Позвонить')

      say('Ирине')
      expect(last_text).to include('нужен выбор кнопкой')
      expect(state['step']).to eq('assignee')
    end

    it 'два параллельных нажатия на последнюю кнопку создают одну задачу' do
      tap_callback("wiz:s:task:#{lead.id}")
      press('Завтра')
      say('Позвонить')
      last = dms.last[:keyboard].flatten.find { |b| b[:text].include?('ответственный по лиду') }[:callback_data]

      # Оба апдейта успели прочитать одно и то же состояние до того, как
      # первый его снял, — как при двойном тапе, разобранном параллельно.
      snapshot = manager.reload.pending_action
      allow(manager).to receive(:pending_action).and_return(snapshot)

      expect do
        tap_callback(last)
        tap_callback(last)
      end.to change(::Task, :count).by(1)
    end

    it 'лид, закрытый пока шёл мастер, задачу не получает' do
      tap_callback("wiz:s:task:#{lead.id}")
      press('Завтра')
      lead.update!(assigned_to: nil, current_stage: 'closed_lost')

      expect { say('Позвонить') }.not_to change(::Task, :count)
      expect(last_text).to include('уже закрыт — задача не создана')
    end

    it 'сбой финального действия отвечает сотруднику, а не молчит' do
      lead.update!(assigned_to: nil)
      allow(Telegram::WorkBot::LeadTaskCreator).to receive(:new).and_raise(ActiveRecord::StatementInvalid, 'boom')
      tap_callback("wiz:s:task:#{lead.id}")
      press('Завтра')

      expect(say('Позвонить')).to eq(:handled)
      expect(last_text).to include('завершился с ошибкой').and include('boom')
      expect(manager.reload.pending_action).to be_nil
    end

    it 'закрытый лид с карточки отсекается до первого вопроса' do
      lead.update!(current_stage: 'closed_lost')
      tap_callback("wiz:s:task:#{lead.id}")

      expect(last_text).to include('уже закрыт')
      expect(manager.reload.pending_action).to be_nil
    end
  end

  describe 'закрытие лида' do
    it 'агенту отказывает до первого вопроса и ничего не собирает' do
      tap_callback("wiz:s:close:#{lead.id}", user: agent, chat_type: 'supergroup')

      expect(last_text).to include('только руководителям')
      expect(agent.reload.pending_action).to be_nil
      expect(acks.last.first).to include('личке')
    end

    it 'проигрыш: исход и причина кнопками, подтверждение закрывает лид' do
      tap_callback("wiz:s:close:#{lead.id}")
      expect(last_text).to include("Чем закончился лид ##{lead.id}?")

      press('Проиграно')
      expect(last_text).to include('Причина отказа?')

      press('Цена')
      expect(last_text).to include('как «проиграно»').and include('причина: цена')

      press('Закрыть лид')
      lead.reload
      expect(lead.current_stage).to eq('closed_lost')
      expect(lead.metadata['close_reason']).to eq('цена')
      expect(last_text).to include("Лид ##{lead.id} закрыт")
      expect(manager.reload.pending_action).to be_nil
    end

    it 'выигрыш не спрашивает причину отказа' do
      tap_callback("wiz:s:close:#{lead.id}")
      press('Выиграно')

      expect(last_text).to include('как «выиграно»')
      press('Закрыть лид')
      expect(lead.reload.current_stage).to eq('closed_won')
      expect(lead.metadata['close_reason']).to be_nil
    end

    it '«Другое» открывает свободный ввод причины' do
      tap_callback("wiz:s:close:#{lead.id}")
      press('Проиграно')
      press('Другое')

      say('купил у застройщика напрямую')
      expect(last_text).to include('причина: купил у застройщика напрямую')
    end

    it 'повторное нажатие подтверждения не закрывает лид второй раз' do
      tap_callback("wiz:s:close:#{lead.id}")
      press('Выиграно')
      confirm = dms.last[:keyboard].flatten.find { |b| b[:text].include?('Закрыть лид') }[:callback_data]
      tap_callback(confirm)

      expect(Telegram::WorkBot::LeadClosure).not_to receive(:new)
      tap_callback(confirm)
      expect(acks.last.last).to be(true)
    end
  end

  describe 'переоткрытие задачи' do
    let!(:recent) do
      ::Task.create!(assignee: agent, title: 'Позвонить Смирновой', status: 'done', kind: 'call',
                     priority: 'normal', completed_at: 3.hours.ago, lead_event: lead)
    end

    it 'задача в окне 24 часа переоткрывается одной кнопкой' do
      tap_callback('wiz:s:reopen', user: agent)
      expect(last_text).to include('Какую задачу переоткрыть?')

      press("##{recent.id}", user: agent)
      expect(recent.reload.status).to eq('open')
      expect(last_text).to include("Задача ##{recent.id} переоткрыта")
    end

    it 'за окном объясняет почему и предлагает новую задачу по тому же лиду' do
      recent.update!(completed_at: 2.days.ago)
      tap_callback('wiz:s:reopen', user: agent)
      press("##{recent.id}", user: agent)

      expect(recent.reload.status).to eq('done')
      expect(last_text).to include('истекло')
      expect(dms.last[:keyboard].flatten.map { |b| b[:callback_data] }).to include("wiz:s:task:#{lead.id}")
    end

    it 'чужую задачу агенту не переоткрыть — шаг повторяется с объяснением' do
      stranger = TelegramUser.create!(tg_user_id: 97_103, tg_username: 'petr', first_name: 'Пётр',
                                      role: 'agent', is_manager: false, status: 'active', dm_chat_id: 97_103)
      tap_callback('wiz:s:reopen', user: stranger)
      press('Ввести номер задачи', user: stranger)

      say(recent.id.to_s, user: stranger)
      expect(last_text).to include('переоткрыть может только исполнитель')
      expect(recent.reload.status).to eq('done')
    end
  end

  describe 'меню «Что сделать?»' do
    it 'агенту не показывает закрытие лида, руководителю показывает' do
      engine(agent).menu
      expect(dms.last[:keyboard].flatten.map { |b| b[:text] }).not_to include('❌ Закрыть лид')

      engine(manager).menu
      expect(dms.last[:keyboard].flatten.map { |b| b[:text] }).to include('❌ Закрыть лид')
    end
  end

  it 'все callback_data укладываются в лимит Telegram 64 байта' do
    tap_callback('wiz:s:close')
    press("##{lead.id}")
    press('Проиграно')
    dms.flat_map { |m| m[:keyboard].flatten }.each do |b|
      expect(b[:callback_data].bytesize).to be <= 64
    end
  end
end
