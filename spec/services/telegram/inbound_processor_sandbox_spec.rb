# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable RSpec/DescribeMethod, RSpec/SpecFilePathFormat -- второй аргумент describe группирует
# спеку по фиче (вход тестового бота), а не по одному методу.
RSpec.describe Telegram::InboundProcessor, 'тестовый бот' do
  let!(:staff) { TelegramUser.create!(tg_user_id: 99_001, status: 'active', dm_chat_id: 99_001) }
  let(:router) { instance_double(Telegram::WorkBot::CallbacksRouter, call: :handled) }

  before { allow(Telegram::WorkBot::CallbacksRouter).to receive(:new).and_return(router) }

  def callback_update(update_id, chat_type: 'private', from: staff.tg_user_id)
    { 'update_id' => update_id,
      'callback_query' => { 'id' => 'cb', 'data' => 'wiz:menu', 'from' => { 'id' => from },
                            'message' => { 'message_id' => 1, 'chat' => { 'id' => from, 'type' => chat_type } } } }
  end

  def process(update, bot)
    Telegram::BotContext.within(bot) { described_class.new(update).call }
  end

  it 'одинаковый update_id у двух ботов — не повтор; у одного бота — повтор' do
    expect(process(callback_update(500), 'main')).to eq(:handled)
    expect(process(callback_update(500), 'test')).to eq(:handled)
    expect(process(callback_update(500), 'test')).to eq(:duplicate)
  end

  it 'тестовый бот игнорирует группы и незнакомых' do
    expect(process(callback_update(501, chat_type: 'supergroup'), 'test')).to eq(:ignored)
    expect(process(callback_update(502, from: 42), 'test')).to eq(:ignored)
    expect(router).not_to have_received(:call)
  end

  it 'тестовый бот не пускает команды и кнопки рабочего бота на боевые данные' do
    task_button = callback_update(503)
    task_button['callback_query']['data'] = 'task:17:done'
    assign = { 'update_id' => 504,
               'message' => { 'message_id' => 5, 'text' => '/assign 12 @irina', 'from' => { 'id' => staff.tg_user_id },
                              'chat' => { 'id' => staff.tg_user_id, 'type' => 'private' } } }

    expect(process(task_button, 'test')).to eq(:ignored)
    expect(process(assign, 'test')).to eq(:ignored)
    expect(router).not_to have_received(:call)
  end

  it 'джоб обрабатывает апдейт в контексте переданного бота' do
    seen = nil
    allow(described_class).to receive(:new) do
      seen = Telegram::BotContext.bot
      instance_double(described_class, call: :ok)
    end

    Telegram::InboundProcessorJob.new.perform({ 'update_id' => 1 }, 'test')

    expect(seen).to eq('test')
  end
end
# rubocop:enable RSpec/DescribeMethod, RSpec/SpecFilePathFormat
