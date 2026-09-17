# frozen_string_literal: true

# Гоняет мастера и кнопки так же, как сотрудник: нажатие берёт callback_data
# из клавиатуры сообщения и идёт через тот обработчик, который выбрал бы
# CallbacksRouter; текст — через Wizard::Engine#text. Так ловится расхождение
# между тем, что нарисовано, и тем, что разбирается.
RSpec.shared_context 'wizard DM harness' do
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

  def last_text
    dms.last[:text]
  end

  def last_callbacks
    dms.last[:keyboard].flatten.map { |b| b[:callback_data] }
  end

  def press(label, user:, message: nil)
    message ||= dms.last
    button = message[:keyboard].flatten.find { |b| b[:text].include?(label) }
    raise "нет кнопки «#{label}» в: #{message[:keyboard].flatten.map { |b| b[:text] }}" unless button

    tap_callback(button[:callback_data], user: user)
  end

  def tap_callback(data, user:, chat_type: 'private')
    prefix, *args = data.split(':')
    handler = Telegram::WorkBot::CallbacksRouter::PREFIX_MAP.fetch(prefix).constantize
    callback_query = { 'id' => 'cb1', 'data' => data, 'from' => { 'id' => user.tg_user_id },
                       'message' => { 'message_id' => 1, 'chat' => { 'id' => user.tg_user_id, 'type' => chat_type } } }
    handler.new(callback_query: callback_query, tg_user: user, args: args, client: tg_client).call
  end

  def say(text, user:)
    Telegram::WorkBot::Wizard::Engine.new(tg_user: user, client: tg_client).text(text)
  end
end
