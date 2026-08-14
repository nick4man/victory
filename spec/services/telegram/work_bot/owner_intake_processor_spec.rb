# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::OwnerIntakeProcessor do
  let!(:tg_user) do
    TelegramUser.create!(tg_user_id: 900_301, tg_username: 'nadya', first_name: 'Надежда',
                         role: 'agent', status: 'active', dm_chat_id: 900_301)
  end
  let!(:agent) { create(:user, role: :agent, telegram_user: tg_user) }
  let!(:property) do
    Property.new(title: 'Объект', price: 5_000_000, address: 'Рязань', district: 'Канищево',
                 user_id: agent.id).tap { |p| p.save!(validate: false) }
  end

  let(:tg_client) { instance_double(Telegram::Client, send_message: { 'message_id' => 1 }) }

  def msg(text: nil, contact: nil, chat_type: 'private', from_id: 900_301)
    { 'from' => { 'id' => from_id }, 'chat' => { 'id' => from_id, 'type' => chat_type },
      'text' => text, 'contact' => contact }.compact
  end

  def expect_pending!
    tg_user.set_pending_action!(type: 'owner_intake', data: { 'property_id' => property.id })
  end

  describe '.applies?' do
    it 'срабатывает только при ожидании контакта' do
      expect(described_class.applies?(msg(text: 'Светлана 9001234567'))).to be false
      expect_pending!
      expect(described_class.applies?(msg(text: 'Светлана 9001234567'))).to be true
    end

    # Без этого условия процессор перехватывал бы любое сообщение в личке и
    # ломал бы остальные сценарии бота.
    it 'не трогает сообщения в группе' do
      expect_pending!
      expect(described_class.applies?(msg(text: 'привет', chat_type: 'supergroup'))).to be false
    end

    it 'не трогает пустые сообщения' do
      expect_pending!
      expect(described_class.applies?(msg)).to be false
    end

    it 'не трогает чужих' do
      expect_pending!
      expect(described_class.applies?(msg(text: 'Светлана 9001234567', from_id: 999_999))).to be false
    end

    # Процессор стоит выше роутера команд. Без этой проверки сотрудник на всё
    # время ожидания терял бы /help, /dashboard, /task: бот отвечал бы «не нашёл
    # телефон», а состояние намеренно не сбрасывается — выйти было бы нечем.
    it 'пропускает команды к роутеру' do
      expect_pending!
      expect(described_class.applies?(msg(text: '/dashboard'))).to be false
      expect(described_class.applies?(msg(text: '  /help'))).to be false
    end

    it 'но карточку контакта принимает всегда' do
      expect_pending!
      expect(described_class.applies?(msg(contact: { 'phone_number' => '79001234567' }))).to be true
    end
  end

  describe 'приём контакта' do
    before { expect_pending! }

    it 'заводит собственника из карточки контакта и привязывает к объекту' do
      described_class.call(msg(contact: { 'phone_number' => '79001234567',
                                          'first_name' => 'Светлана' }), client: tg_client)

      owner = property.reload.owner_user
      expect(owner).to be_present
      expect(owner.phone).to eq('+79001234567')
      expect(owner.role).to eq('client')
    end

    it 'заводит собственника из текста' do
      described_class.call(msg(text: 'Пётр Иванов +7 900 555-44-33'), client: tg_client)

      owner = property.reload.owner_user
      expect(owner.first_name).to eq('Пётр')
      expect(owner.phone).to eq('+79005554433')
    end

    it 'предлагает отправить приглашение кнопкой' do
      described_class.call(msg(text: 'Светлана 9001234567'), client: tg_client)

      expect(tg_client).to have_received(:send_message) do |_text, opts|
        actions = opts[:reply_markup][:inline_keyboard].flatten.map { |b| b[:callback_data] }
        expect(actions).to include("owner:invite:#{property.id}")
      end
    end

    it 'снимает ожидание после успеха' do
      described_class.call(msg(text: 'Светлана 9001234567'), client: tg_client)
      expect(tg_user.reload.pending_action).to be_nil
    end

    it 'связывает с уже существующим клиентом, а не заводит дубль' do
      existing = create(:user, role: :client, phone: '+79001234567')

      expect do
        described_class.call(msg(text: 'Светлана 9001234567'), client: tg_client)
      end.not_to change(User, :count)

      expect(property.reload.owner_user_id).to eq(existing.id)
    end
  end

  describe 'когда контакт не разобрался' do
    before { expect_pending! }

    # Состояние не сбрасываем: человек уже согласился прислать контакт, и терять
    # этот шаг из-за опечатки значит начинать сначала.
    it 'переспрашивает и сохраняет ожидание' do
      described_class.call(msg(text: 'посмотрю позже'), client: tg_client)

      expect(property.reload.owner_user_id).to be_nil
      expect(tg_user.reload.pending_action).to be_present
      expect(tg_client).to have_received(:send_message).with(
        a_string_matching(/Не нашёл в сообщении телефон или почту/), any_args
      )
    end
  end

  describe 'когда объект исчез' do
    it 'снимает ожидание и объясняет' do
      tg_user.set_pending_action!(type: 'owner_intake', data: { 'property_id' => 0 })

      described_class.call(msg(text: 'Светлана 9001234567'), client: tg_client)

      expect(tg_user.reload.pending_action).to be_nil
      expect(tg_client).to have_received(:send_message).with(
        a_string_matching(/Объект не найден/), any_args
      )
    end
  end

  # Агент присылает собственный контакт — приглашение уйдёт ему самому, и
  # договор он подпишет за «собственника». Запретить нельзя (агент может
  # продавать свою квартиру), поэтому связь остаётся, но перестаёт быть тихой.
  describe 'когда агент указал собственником себя' do
    let!(:director) do
      TelegramUser.create!(tg_user_id: 900_777, first_name: 'Оксана', role: 'director',
                           status: 'active', dm_chat_id: 900_777)
    end

    before do
      agent.update_column(:phone, '+79001234567')
      expect_pending!
    end

    it 'всё равно привязывает — законный случай неотличим от подлога' do
      described_class.call(msg(text: 'Надежда 9001234567'), client: tg_client)

      expect(property.reload.owner_user_id).to eq(agent.id)
    end

    it 'предупреждает директора' do
      described_class.call(msg(text: 'Надежда 9001234567'), client: tg_client)

      expect(tg_client).to have_received(:send_message).with(
        a_string_matching(/указал собственником объекта .* самого себя/), hash_including(chat_id: 900_777)
      )
    end

    it 'молчит, когда собственник — не сам агент' do
      described_class.call(msg(text: 'Светлана 9005554433'), client: tg_client)

      expect(tg_client).not_to have_received(:send_message).with(
        a_string_matching(/самого себя/), any_args
      )
    end
  end

  describe 'когда собственник уже указан' do
    it 'не перетирает связь' do
      first_owner = create(:user, role: :client)
      property.update_column(:owner_user_id, first_owner.id)
      expect_pending!

      described_class.call(msg(text: 'Другой Человек +7 900 000-11-22'), client: tg_client)

      expect(property.reload.owner_user_id).to eq(first_owner.id)
      expect(tg_client).to have_received(:send_message).with(
        a_string_matching(/уже указан собственник/), any_args
      )
    end
  end
end
