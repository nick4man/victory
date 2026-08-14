# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Callbacks::OwnerRequestCallback do
  let!(:tg_user) do
    TelegramUser.create!(tg_user_id: 900_401, tg_username: 'nadya', first_name: 'Надежда',
                         role: 'agent', status: 'active', dm_chat_id: 900_401)
  end
  let!(:agent) { create(:user, role: :agent, telegram_user: tg_user) }
  let!(:property) do
    Property.new(title: 'Объект', price: 5_000_000, address: 'Рязань', district: 'Канищево',
                 user_id: agent.id).tap { |p| p.save!(validate: false) }
  end

  let(:tg_client) do
    instance_double(Telegram::Client, send_message: { 'message_id' => 1 },
                                      answer_callback_query: { 'ok' => true })
  end

  def build_cb(data)
    { 'id' => 'cb_1', 'from' => { 'id' => tg_user.tg_user_id }, 'data' => data,
      'message' => { 'message_id' => 7, 'chat' => { 'id' => tg_user.tg_user_id, 'type' => 'private' } } }
  end

  def invoke(action, id = property.id)
    described_class.new(callback_query: build_cb("owner:#{action}:#{id}"), tg_user: tg_user,
                        args: [action, id.to_s], client: tg_client).call
  end

  describe 'прислать контакт' do
    it 'переводит бота в ожидание контакта по этому объекту' do
      invoke('contact')

      pending = tg_user.reload.pending_action
      expect(pending['type']).to eq('owner_intake')
      expect(pending.dig('data', 'property_id')).to eq(property.id)
    end

    it 'объясняет, что можно прислать' do
      invoke('contact')
      expect(tg_client).to have_received(:send_message).with(
        a_string_matching(/карточку контакта|текстом/), any_args
      )
    end
  end

  describe 'отложить' do
    it 'ставит отсрочку' do
      invoke('snooze')
      expect(property.reload.owner_request_snoozed_until).to be > 6.days.from_now
    end
  end

  describe 'не мой объект' do
    let!(:director) do
      TelegramUser.create!(tg_user_id: 900_402, tg_username: 'oks', first_name: 'Оксана',
                           role: 'director', is_manager: true, status: 'active',
                           dm_chat_id: 900_402)
    end

    it 'помечает объект и больше не спрашивает' do
      invoke('decline')
      expect(property.reload.owner_request_declined_at).to be_present
    end

    # Ответственный указан неверно — это правится человеком в CRM, а не
    # повторной рассылкой тому же агенту.
    it 'сообщает директору, что нужно поправить ответственного' do
      invoke('decline')
      expect(tg_client).to have_received(:send_message).with(
        a_string_matching(/не его.*поправить ответственного/m),
        hash_including(chat_id: director.dm_chat_id)
      )
    end
  end

  describe 'отправить приглашение' do
    it 'зовёт диспетчер приглашений без SMS' do
      owner = create(:user, role: :client, email: 'owner@example.ru')
      property.update_column(:owner_user_id, owner.id)
      allow(CabinetInvitationDispatcher).to receive(:call)

      invoke('invite')

      expect(CabinetInvitationDispatcher).to have_received(:call)
        .with(owner, property, channels: %i[email tg])
    end

    it 'отказывается, когда собственника ещё нет' do
      allow(CabinetInvitationDispatcher).to receive(:call)

      invoke('invite')

      expect(CabinetInvitationDispatcher).not_to have_received(:call)
      expect(tg_client).to have_received(:answer_callback_query)
        .with('cb_1', hash_including(text: a_string_matching(/нет собственника/)))
    end

    # Главный реальный случай: контакт прислали одним телефоном, без почты.
    # Диспетчер НЕ бросает исключений — он возвращает Result с пустым
    # channels_succeeded. Раньше код смотрел только на отсутствие исключения и
    # отвечал «отправлено», а собственник не получал ничего.
    it 'не называет отправкой то, что никуда не ушло' do
      # Именно так заводит клиента Crm::OwnerLinker, когда агент прислал один
      # телефон: без email и без телеграма. Фабрика такого не даёт — там email
      # обязателен.
      owner = User.new(first_name: 'Светлана', last_name: '—', role: :client,
                       phone: '+79001234567', active: true)
      owner.save!(validate: false)
      property.update_column(:owner_user_id, owner.id)
      allow(CabinetInvitationDispatcher).to receive(:call).and_return(
        CabinetInvitationDispatcher::Result.new(channels_attempted: [], channels_succeeded: [], errors: [])
      )

      invoke('invite')

      expect(tg_client).to have_received(:send_message).with(
        a_string_matching(/НЕ отправлено.*нет ни почты, ни телеграма/m), any_args
      )
      expect(tg_client).to have_received(:answer_callback_query)
        .with('cb_1', hash_including(show_alert: true))
    end

    it 'подтверждает отправку, когда канал действительно сработал' do
      owner = create(:user, role: :client, email: 'owner@example.ru')
      property.update_column(:owner_user_id, owner.id)
      allow(CabinetInvitationDispatcher).to receive(:call).and_return(
        CabinetInvitationDispatcher::Result.new(channels_attempted: [:email],
                                                channels_succeeded: [:email], errors: [])
      )

      invoke('invite')

      expect(tg_client).to have_received(:send_message).with(
        a_string_matching(/✅ Приглашение отправлено \(email\)/), any_args
      )
    end

    # Падение внешнего канала не должно выглядеть как успешная отправка.
    it 'сообщает о неудаче, а не молчит' do
      owner = create(:user, role: :client)
      property.update_column(:owner_user_id, owner.id)
      allow(CabinetInvitationDispatcher).to receive(:call).and_raise(StandardError, 'smtp')

      invoke('invite')

      expect(tg_client).to have_received(:answer_callback_query)
        .with('cb_1', hash_including(text: a_string_matching(/Не удалось/), show_alert: true))
    end
  end

  describe 'отмена' do
    # Пока бот ждёт контакт, он пропускает команды мимо себя — без кнопки
    # отмены выйти из режима было бы нечем до истечения срока.
    it 'снимает ожидание' do
      invoke('contact')
      expect(tg_user.reload.pending_action).to be_present

      invoke('cancel')
      expect(tg_user.reload.pending_action).to be_nil
    end

    it 'предлагается вместе с запросом контакта' do
      invoke('contact')
      expect(tg_client).to have_received(:send_message) do |_text, opts|
        actions = opts[:reply_markup][:inline_keyboard].flatten.map { |b| b[:callback_data] }
        expect(actions).to include("owner:cancel:#{property.id}")
      end
    end
  end

  describe 'чужой объект' do
    let!(:other_agent) { create(:user, role: :agent) }

    # decline навсегда выключает объект из опроса, invite шлёт письмо
    # собственнику — по чужому объекту это делать нельзя.
    it 'не даёт агенту трогать объект коллеги' do
      property.update_column(:user_id, other_agent.id)

      invoke('decline')

      expect(property.reload.owner_request_declined_at).to be_nil
      expect(tg_client).to have_received(:answer_callback_query)
        .with('cb_1', hash_including(text: a_string_matching(/не ваш объект/)))
    end

    it 'директору разрешает — он и разбирает спорные случаи' do
      property.update_column(:user_id, other_agent.id)
      tg_user.update_columns(role: 'director', is_manager: true)

      invoke('decline')

      expect(property.reload.owner_request_declined_at).to be_present
    end
  end

  describe 'несуществующий объект' do
    it 'отвечает внятно' do
      invoke('contact', 0)
      expect(tg_client).to have_received(:answer_callback_query)
        .with('cb_1', hash_including(text: a_string_matching(/не найден/)))
    end
  end
end
