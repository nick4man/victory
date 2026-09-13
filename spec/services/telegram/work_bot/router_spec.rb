# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Router do
  let(:sent) { [] }
  let(:tg_client) do
    client = instance_double(Telegram::Client)
    allow(client).to receive(:send_message) { |text, **_opts| sent << text; { 'message_id' => 1 } }
    client
  end

  def dispatch(text, from_id:)
    msg = { 'from' => { 'id' => from_id }, 'chat' => { 'id' => from_id, 'type' => 'private' },
            'message_id' => 11, 'text' => text }
    described_class.new(msg, client: tg_client).call
  end

  it 'клиенту (нет строки в telegram_users) не показывает подсказку про /whoami' do
    expect(dispatch('/квартира', from_id: 999)).to eq(:client_hint)
    expect(sent.join).not_to include('/whoami')
  end

  it 'сотруднику на нераспознанную команду отвечает как раньше' do
    TelegramUser.create!(tg_user_id: 777, role: 'agent', first_name: 'A',
                         is_manager: false, status: 'active', dm_chat_id: 777)
    expect(dispatch('/нетакой', from_id: 777)).to eq(:unknown_command)
    expect(sent.join).to include('/whoami')
  end

  it 'экранирует команду в ответе — /<b от клиента не роняет sendMessage' do
    TelegramUser.create!(tg_user_id: 778, role: 'agent', first_name: 'B',
                         is_manager: false, status: 'active', dm_chat_id: 778)
    dispatch('/<b', from_id: 778)
    expect(sent.join).to include('&lt;b')
  end

  # ── Разбор команды ──────────────────────────────────────────────────────
  describe 'разбор команды' do
    let!(:staff) do
      TelegramUser.create!(tg_user_id: 780, tg_username: 'irina', role: 'agent', first_name: 'Ирина',
                           is_manager: false, status: 'active', dm_chat_id: 780)
    end

    # В группах Telegram сам дописывает @bot_name к команде. Без снятия суффикса
    # ни одна команда из группы не находилась бы в COMMANDS — то есть бот молчал
    # бы ровно там, где им пользуются.
    it 'снимает суффикс @bot_name перед поиском в реестре' do
      expect(dispatch('/help@victory62_bot', from_id: staff.tg_user_id)).to eq(:handled)
      expect(sent.join).not_to include('не распознана')
    end

    it 'регистр команды не важен' do
      expect(dispatch('/HELP', from_id: staff.tg_user_id)).to eq(:handled)
    end

    it 'пустое сообщение игнорирует' do
      expect(described_class.new({}, client: tg_client).call).to eq(:ignored)
    end

    it 'обычный текст (не команду) не трогает — им занимаются другие обработчики' do
      expect(dispatch('здравствуйте, есть двушка?', from_id: staff.tg_user_id)).to eq(:ignored)
      expect(sent).to be_empty
    end

    it 'алиасы указывают на те же обработчики, что и основные команды' do
      cmds = described_class::COMMANDS
      expect(cmds['/panel']).to eq(cmds['/dashboard'])
      expect(cmds['/shortcuts']).to eq(cmds['/cheatsheet'])
      expect(cmds['/start']).to eq(cmds['/help'])
    end
  end

  # ── DM-верификация кода ─────────────────────────────────────────────────
  describe 'шестизначный код в личке' do
    let!(:staff) do
      TelegramUser.create!(tg_user_id: 781, role: 'agent', first_name: 'Ирина',
                           is_manager: false, status: 'active', dm_chat_id: 781)
    end

    it 'верный код завершает привязку' do
      allow(Telegram::WorkBot::Commands::Whoami).to receive(:verify_code).and_return(true)
      expect(dispatch('123456', from_id: staff.tg_user_id)).to eq(:verified)
    end

    it 'неверный код объясняет, как запросить новый' do
      allow(Telegram::WorkBot::Commands::Whoami).to receive(:verify_code).and_return(false)
      expect(dispatch('123456', from_id: staff.tg_user_id)).to eq(:code_failed)
      expect(sent.join).to include('/whoami')
    end

    it 'в группе шестизначное число кодом не считается' do
      msg = { 'from' => { 'id' => staff.tg_user_id },
              'chat' => { 'id' => -1_003_779_115_845, 'type' => 'supergroup' },
              'message_id' => 12, 'text' => '123456' }
      expect(Telegram::WorkBot::Commands::Whoami).not_to receive(:verify_code)
      expect(described_class.new(msg, client: tg_client).call).to eq(:ignored)
    end

    it 'число другой длины кодом не считается' do
      allow(Telegram::WorkBot::Commands::Whoami).to receive(:verify_code)
      expect(dispatch('12345', from_id: staff.tg_user_id)).to eq(:ignored)
      expect(Telegram::WorkBot::Commands::Whoami).not_to have_received(:verify_code)
    end
  end

  # ── /learn_topic ────────────────────────────────────────────────────────
  # Ручная привязка топика — запасной путь, когда автоматический discovery
  # промахнулся (имя топика в TG разошлось с YAML). Порядок проверок в коде
  # именно такой: формат → валидность ключа → права.
  describe '/learn_topic' do
    let!(:manager) do
      TelegramUser.create!(tg_user_id: 782, tg_username: 'oks', role: 'manager', first_name: 'Оксана',
                           is_manager: true, status: 'active', dm_chat_id: 782)
    end
    let!(:agent) do
      TelegramUser.create!(tg_user_id: 783, tg_username: 'irina', role: 'agent', first_name: 'Ирина',
                           is_manager: false, status: 'active', dm_chat_id: 783)
    end

    def in_topic(text, from_id:, thread_id: 17)
      msg = { 'from' => { 'id' => from_id },
              'chat' => { 'id' => -1_003_779_115_845, 'type' => 'supergroup' },
              'message_id' => 13, 'message_thread_id' => thread_id, 'text' => text }
      described_class.new(msg, client: tg_client).call
    end

    it 'руководитель привязывает ключ к thread_id текущего топика' do
      expect(Telegram::TopicRegistry).to receive(:record_discovery).with('apartments', 17)
      in_topic('/learn_topic apartments', from_id: manager.tg_user_id)
      expect(sent.join).to include('apartments')
    end

    it 'вне топика объясняет, что команда работает только внутри топика' do
      allow(Telegram::TopicRegistry).to receive(:record_discovery)
      in_topic('/learn_topic apartments', from_id: manager.tg_user_id, thread_id: nil)
      expect(Telegram::TopicRegistry).not_to have_received(:record_discovery)
      expect(sent.join).to include('только внутри топика')
    end

    it 'неизвестный ключ отклоняет до проверки прав' do
      allow(Telegram::TopicRegistry).to receive(:record_discovery)
      in_topic('/learn_topic atlantis', from_id: manager.tg_user_id)
      expect(Telegram::TopicRegistry).not_to have_received(:record_discovery)
      expect(sent.join).to include('Неизвестный ключ')
    end

    it 'агенту привязку не даёт' do
      allow(Telegram::TopicRegistry).to receive(:record_discovery)
      in_topic('/learn_topic apartments', from_id: agent.tg_user_id)
      expect(Telegram::TopicRegistry).not_to have_received(:record_discovery)
      expect(sent.join).to include('Только для руководителей')
    end
  end
end
