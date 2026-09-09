# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Callbacks::TutorialCallback do
  let(:tg_client) do
    instance_double(Telegram::Client,
                    send_message: { 'message_id' => 100 },
                    edit_message_text: { 'message_id' => 100 },
                    answer_callback_query: { 'ok' => true })
  end
  let(:director) do
    TelegramUser.create!(tg_user_id: 143_001, tg_username: 'oks', first_name: 'Оксана',
                         role: 'director', is_manager: true, status: 'active', dm_chat_id: 143_001)
  end

  def callback_query(data, chat_type: 'private')
    { 'id' => 'cb-1', 'data' => data,
      'from' => { 'id' => director.tg_user_id },
      'message' => { 'message_id' => 55,
                     'chat' => { 'id' => director.dm_chat_id, 'type' => chat_type } } }
  end

  def run(data, chat_type: 'private')
    args = data.split(':').drop(1)
    described_class.new(callback_query: callback_query(data, chat_type: chat_type),
                        tg_user: director, args: args, client: tg_client).call
  end

  describe 'листание уроков' do
    it 'перерисовывает ту же карточку, а не шлёт новую' do
      run('tutorial:go:1')

      expect(tg_client).to have_received(:edit_message_text).once.with(
        a_string_including('Урок 2 из'),
        hash_including(chat_id: director.dm_chat_id, message_id: 55,
                       reply_markup: hash_including(:inline_keyboard))
      )
      expect(tg_client).not_to have_received(:send_message)
    end

    it 'всегда отвечает Telegram, чтобы кнопка не крутилась' do
      run('tutorial:go:1')

      expect(tg_client).to have_received(:answer_callback_query).with('cb-1', anything)
    end

    it 'индекс за пределами курса упирается в последний урок, а не падает' do
      last = Telegram::WorkBot::TutorialLessons.visible_for(director).size

      run('tutorial:go:99')

      expect(tg_client).to have_received(:edit_message_text).with(
        a_string_including("Урок #{last} из #{last}"), anything
      )
    end
  end

  describe 'финал' do
    it 'снимает клавиатуру и отправляет к шпаргалке' do
      run('tutorial:finish')

      expect(tg_client).to have_received(:edit_message_text).with(
        a_string_including('/cheatsheet'),
        hash_including(reply_markup: { inline_keyboard: [] })
      )
    end
  end

  describe 'кнопка нажата вне лички' do
    it 'отвечает алертом и ничего не редактирует' do
      run('tutorial:go:1', chat_type: 'supergroup')

      expect(tg_client).to have_received(:answer_callback_query)
        .with('cb-1', hash_including(show_alert: true))
      expect(tg_client).not_to have_received(:edit_message_text)
    end
  end

  describe 'ошибки Telegram при редактировании' do
    it 'повторное нажатие того же урока не плодит карточки' do
      allow(tg_client).to receive(:edit_message_text)
        .and_raise(Telegram::Client::Error, 'Bad Request: message is not modified')

      run('tutorial:go:1')

      expect(tg_client).not_to have_received(:send_message)
      expect(tg_client).to have_received(:answer_callback_query)
    end

    it 'на устаревшем сообщении открывает свежую карточку' do
      allow(tg_client).to receive(:edit_message_text)
        .and_raise(Telegram::Client::Error, 'Bad Request: message to edit not found')

      run('tutorial:go:1')

      expect(tg_client).to have_received(:send_message).once.with(
        a_string_including('Урок 2 из'), hash_including(chat_id: director.dm_chat_id)
      )
    end
  end

  describe 'неизвестное действие' do
    it 'сообщает алертом, не редактируя карточку' do
      run('tutorial:wat')

      expect(tg_client).to have_received(:answer_callback_query)
        .with('cb-1', hash_including(show_alert: true))
      expect(tg_client).not_to have_received(:edit_message_text)
    end
  end
end
