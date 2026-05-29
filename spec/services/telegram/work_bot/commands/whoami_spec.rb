# frozen_string_literal: true

require 'rails_helper'

# Phase 16.7 — фокус на BotCommandLog.error_message population
# в error-class results (invalid_email / email_not_in_topnlab / topnlab_api_error).
# args column тоже остаётся заполнен для backward compat.
RSpec.describe Telegram::WorkBot::Commands::Whoami do
  let(:from_id) { 40_001 }
  let(:tg_client) { instance_double(Telegram::Client, send_message: { 'message_id' => 1 }) }
  let(:topnlab_client) do
    instance_double(Topnlab::Client, get_users: [{ 'email' => 'agent@victory.ru', 'id' => 1 }])
  end

  before do
    allow(Telegram::Client).to receive(:new).and_return(tg_client)
    allow(Topnlab::Client).to receive(:new).and_return(topnlab_client)
  end

  def message(text)
    { 'message_id' => 1, 'from' => { 'id' => from_id }, 'chat' => { 'id' => from_id, 'type' => 'private' },
      'text' => text }
  end

  def call_whoami(text)
    cmd, rest = text.split(/\s+/, 2)
    handler = described_class.new(message: message(text), args: rest, tg_user: nil, client: tg_client)
    handler.call
  end

  describe 'BotCommandLog.error_message population' do
    it 'invalid_email — пишет args И error_message' do
      expect { call_whoami('/whoami foo_no_at_sign') }.to change(BotCommandLog, :count).by(1)
      log = BotCommandLog.last
      expect(log.result).to eq('invalid_email')
      expect(log.args).to eq('foo_no_at_sign')
      expect(log.error_message).to eq('foo_no_at_sign')
    end

    it 'email_not_in_topnlab — пишет error_message' do
      allow(topnlab_client).to receive(:get_users).and_return([])
      expect { call_whoami('/whoami missing@victory.ru') }.to change(BotCommandLog, :count).by(1)
      log = BotCommandLog.last
      expect(log.result).to eq('email_not_in_topnlab')
      expect(log.error_message).to eq('missing@victory.ru')
    end

    it 'topnlab_api_error — пишет error_message (включает класс ошибки)' do
      # Note: при topnlab raise существующий код логирует 2 entries —
      # сначала topnlab_api_error из rescue, потом email_not_in_topnlab из
      # main flow (т.к. find_topnlab_user вернул nil). Проверяем что НАШ
      # topnlab_api_error log заполнил error_message.
      allow(topnlab_client).to receive(:get_users).and_raise(Topnlab::Client::Error, 'API timeout')
      call_whoami('/whoami agent@victory.ru')
      api_error_log = BotCommandLog.where(result: 'topnlab_api_error').last
      expect(api_error_log).not_to be_nil
      expect(api_error_log.error_message).to include('API timeout')
    end

    it 'usage (success result) — error_message остаётся nil' do
      expect { call_whoami('/whoami') }.to change(BotCommandLog, :count).by(1)
      log = BotCommandLog.last
      expect(log.result).to eq('usage')
      expect(log.error_message).to be_nil
    end

    it 'code_sent (success result) — error_message остаётся nil' do
      expect { call_whoami('/whoami agent@victory.ru') }.to change(BotCommandLog, :count).by(1)
      log = BotCommandLog.last
      expect(log.result).to eq('code_sent')
      expect(log.error_message).to be_nil
    end
  end
end
