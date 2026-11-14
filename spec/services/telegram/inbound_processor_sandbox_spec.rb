# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable RSpec/DescribeMethod, RSpec/SpecFilePathFormat -- второй аргумент describe группирует
# спеку по фиче (вход тестового бота), а не по одному методу.
RSpec.describe Telegram::InboundProcessor, 'тестовый бот' do
  let!(:staff) { TelegramUser.create!(tg_user_id: 99_001, status: 'active', dm_chat_id: 99_001) }
  let(:router) { instance_double(Telegram::WorkBot::CallbacksRouter, call: :handled) }

  before do
    # Ack отказа (item 3) реально дёргает Telegram::Client — нужен непустой
    # тестовый токен, иначе Client.new падает до отправки запроса.
    stub_const('ENV', ENV.to_h.merge('TELEGRAM_TEST_BOT_TOKEN' => 'test-token'))
    allow(Telegram::WorkBot::CallbacksRouter).to receive(:new).and_return(router)
  end

  def callback_update(update_id, chat_type: 'private', from: staff.tg_user_id)
    { 'update_id' => update_id,
      'callback_query' => { 'id' => 'cb', 'data' => 'wiz:menu', 'from' => { 'id' => from },
                            'message' => { 'message_id' => 1, 'chat' => { 'id' => from, 'type' => chat_type } } } }
  end

  def process(update, bot)
    Telegram::BotContext.within(bot) { described_class.new(update).call }
  end

  def message_update(update_id, from: staff.tg_user_id, chat_type: 'private', text: nil, extra: {})
    msg = { 'message_id' => update_id, 'from' => { 'id' => from }, 'chat' => { 'id' => from, 'type' => chat_type } }
    msg['text'] = text if text
    { 'update_id' => update_id, 'message' => msg.merge(extra) }
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

  it 'voice при активном crm_ мастере в тестовом боте — не платим за транскрибацию боевого pipeline' do
    staff.set_pending_action!(type: 'wizard', data: { 'flow' => 'crm_edit', 'bot' => 'test' }, step: 'value')
    expect(Telegram::WorkBot::VoiceIntakeProcessor).not_to receive(:applies?)

    update = message_update(510, extra: { 'voice' => { 'file_id' => 'v1' } })

    expect(process(update, 'test')).to eq(:ignored)
  end

  it 'фото при активном crm_ мастере в тестовом боте — не платим за боевой pipeline' do
    staff.set_pending_action!(type: 'wizard', data: { 'flow' => 'crm_edit', 'bot' => 'test' }, step: 'value')
    expect(Telegram::WorkBot::PhotoIntakeProcessor).not_to receive(:applies?)

    update = message_update(511, extra: { 'photo' => [{ 'file_id' => 'p1' }] })

    expect(process(update, 'test')).to eq(:ignored)
  end

  it 'свободный текст игнорируется, если crm_ мастер висит в рабочем боте, а не в тестовом' do
    staff.set_pending_action!(type: 'wizard', data: { 'flow' => 'crm_edit', 'bot' => 'main' }, step: 'value')
    expect(Telegram::WorkBot::Router).not_to receive(:new)
    expect(Telegram::WorkBot::DmQnaHandler).not_to receive(:call)

    update = message_update(512, text: 'завтра')

    expect(process(update, 'test')).to eq(:ignored)
  end

  it 'отклонённый callback_query от известного сотрудника получает answerCallbackQuery — иначе спиннер висит' do
    task_button = callback_update(513)
    task_button['callback_query']['data'] = 'task:17:done'

    expect(process(task_button, 'test')).to eq(:ignored)

    expect(a_request(:post, %r{answerCallbackQuery})
      .with(body: hash_including('callback_query_id' => 'cb', 'text' => 'В тестовом боте недоступно.')))
      .to have_been_made.once
  end
end
# rubocop:enable RSpec/DescribeMethod, RSpec/SpecFilePathFormat
