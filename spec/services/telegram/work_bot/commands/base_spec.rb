# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Commands::Base do
  let(:tg_client) { instance_double(Telegram::Client, send_message: { 'message_id' => 1 }) }
  let(:msg) { { 'from' => { 'id' => 555 }, 'chat' => { 'id' => 555, 'type' => 'private' }, 'message_id' => 7 } }
  let(:agent) do
    TelegramUser.create!(tg_user_id: 555, role: 'agent', first_name: 'A',
                         is_manager: false, status: 'active', dm_chat_id: 555)
  end

  # Минимальная команда-наследник: не хочется привязывать спеку базы
  # к поведению конкретной команды.
  let(:ok_command) do
    Class.new(described_class) do
      def self.name
        'Telegram::WorkBot::Commands::FakeOk'
      end

      def handle
        :handled
      end
    end
  end

  let(:boom_command) do
    Class.new(described_class) do
      def self.name
        'Telegram::WorkBot::Commands::FakeBoom'
      end

      def handle
        raise StandardError, 'boom'
      end
    end
  end

  it 'пишет BotCommandLog на успешный вызов' do
    expect {
      ok_command.new(message: msg, args: 'нал', tg_user: agent, client: tg_client).call
    }.to change(BotCommandLog, :count).by(1)

    log = BotCommandLog.order(:created_at).last
    expect(log.tg_user_id).to eq(555)
    expect(log.command).to eq('fake_ok')
    expect(log.args).to eq('нал')
    expect(log.result).to eq('handled')
  end

  it 'пишет отказ, а не тишину, когда отправителя нет в telegram_users' do
    klass = Class.new(described_class) do
      def self.name
        'Telegram::WorkBot::Commands::FakeManager'
      end

      manager_only

      def handle
        :handled
      end
    end

    klass.new(message: msg, args: '', tg_user: nil, client: tg_client).call
    expect(BotCommandLog.order(:created_at).last.result).to eq('denied_not_staff')
  end

  it 'пишет отказ по роли' do
    klass = Class.new(described_class) do
      def self.name
        'Telegram::WorkBot::Commands::FakeManager2'
      end

      manager_only

      def handle
        :handled
      end
    end

    klass.new(message: msg, args: '', tg_user: agent, client: tg_client).call
    expect(BotCommandLog.order(:created_at).last.result).to eq('denied_manager')
  end

  it 'пишет error_class и error_message при исключении' do
    boom_command.new(message: msg, args: '', tg_user: agent, client: tg_client).call
    log = BotCommandLog.order(:created_at).last
    expect(log.result).to eq('error')
    expect(log.error_class).to eq('StandardError')
    expect(log.error_message).to eq('boom')
  end

  it 'падение аудита не ломает команду' do
    allow(BotCommandLog).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, 'db down')
    expect(ok_command.new(message: msg, args: '', tg_user: agent, client: tg_client).call).to eq(:handled)
  end
end
