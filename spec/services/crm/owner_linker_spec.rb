# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Crm::OwnerLinker do
  describe '.normalize_phone' do
    # Российский номер пишут четырьмя способами. Без единого вида поиск дубля
    # не находит человека и заводит второго — а объекты у него разъезжаются.
    it 'приводит все записи одного номера к общему виду' do
      %w[+79001234567 79001234567 89001234567].each do |raw|
        expect(described_class.normalize_phone(raw)).to eq('+79001234567')
      end
      expect(described_class.normalize_phone('8 (900) 123-45-67')).to eq('+79001234567')
    end

    # Голые десять цифр — самый частый ответ агента. Раньше получалось
    # `+9001234567`, без кода страны: правило пришло из Topnlab-синка, где на
    # вход шли номера вида `79…`. В проде такой мусор уже лежит (`+9209780508`).
    it 'достраивает код страны к десятизначному номеру' do
      expect(described_class.normalize_phone('9001234567')).to eq('+79001234567')
    end

    it 'возвращает nil, когда цифр нет' do
      expect(described_class.normalize_phone('нет номера')).to be_nil
      expect(described_class.normalize_phone(nil)).to be_nil
    end
  end

  describe '.from_contact' do
    it 'создаёт клиента по телефону' do
      user, created = described_class.from_contact(first_name: 'Светлана', phone: '8 900 123-45-67')

      expect(created).to be true
      expect(user.role).to eq('client')
      expect(user.phone).to eq('+79001234567')
      expect(user.first_name).to eq('Светлана')
    end

    it 'создаёт клиента по email' do
      user, created = described_class.from_contact(email: 'Sveta@Example.RU', last_name: 'Петрова')

      expect(created).to be true
      expect(user.email).to eq('sveta@example.ru')
    end

    it 'отказывается создавать без контактов' do
      user, created = described_class.from_contact(first_name: 'Никто')

      expect(user).to be_nil
      expect(created).to be false
    end

    it 'подставляет заглушки вместо пустого имени' do
      user, = described_class.from_contact(phone: '+79001110000')
      expect(user.first_name).to eq('Клиент')
      expect(user.last_name).to eq('—')
    end
  end

  describe 'поиск существующего' do
    it 'находит по email без учёта регистра и не плодит дубль' do
      existing = create(:user, role: :client, email: 'owner@example.ru')

      user, created = described_class.from_contact(email: 'OWNER@Example.ru')

      expect(user).to eq(existing)
      expect(created).to be false
    end

    # Телефон в базе и телефон из телеграма записаны по-разному — сравнение
    # идёт по последним десяти цифрам, иначе один человек заведётся дважды.
    it 'находит по телефону, записанному в другом формате' do
      existing = create(:user, role: :client, phone: '+79005554433')

      user, created = described_class.from_contact(phone: '8 (900) 555-44-33')

      expect(user).to eq(existing)
      expect(created).to be false
    end

    it 'не принимает админа за собственника при совпадении телефона' do
      create(:user, role: :admin, phone: '+79007778899')

      user, created = described_class.from_contact(phone: '+79007778899', first_name: 'Другой')

      expect(user.role).to eq('client')
      expect(created).to be true
    end

    # Мягко удалённая учётка не считается существующей, но продолжает занимать
    # email в unique-индексе. Создать нового с тем же адресом нельзя, поэтому
    # возвращаем nil, а не воскрешаем запись: удаление могло быть по 152-ФЗ, и
    # молча вернуть человека в систему было бы неверно. Разбирается человеком.
    it 'не воскрешает удалённого клиента и не заводит дубль по занятому email' do
      create(:user, role: :client, email: 'gone@example.ru', deleted_at: Time.current)

      user, created = described_class.from_contact(email: 'gone@example.ru')

      expect(user).to be_nil
      expect(created).to be false
    end
  end

  describe '.from_topnlab' do
    # Формат Topnlab: контакты либо строкой, либо массивом с признаком главного.
    it 'берёт основной контакт из массива, а не первый попавшийся' do
      data = {
        'id' => 555,
        'firstname' => 'Иван',
        'lastname' => 'Сидоров',
        'emails' => [{ 'value' => 'second@example.ru', 'is_main' => 0 },
                     { 'value' => 'Main@Example.ru', 'is_main' => 1 }],
        'phones' => [{ 'value' => '89002223344', 'is_main' => 1 }]
      }

      user, created = described_class.from_topnlab(data)

      expect(created).to be true
      expect(user.email).to eq('main@example.ru')
      expect(user.phone).to eq('+79002223344')
      expect(user.crm_user_id).to eq(555)
    end

    it 'понимает контакты, переданные строкой' do
      user, = described_class.from_topnlab('firstname' => 'Пётр', 'email' => 'p@example.ru')
      expect(user.email).to eq('p@example.ru')
    end

    it 'пропускает клиента без контактов' do
      user, created = described_class.from_topnlab('firstname' => 'Безымянный')
      expect(user).to be_nil
      expect(created).to be false
    end
  end

  describe '.attach!' do
    # Фабрики :property в проекте нет, а полноценный объект здесь не нужен —
    # проверяется только установка связи. Создаём минимум по NOT NULL-колонкам.
    let(:property) do
      agent = create(:user, role: :agent)
      Property.new(title: 'Тестовый объект', price: 1_000_000, address: 'Рязань',
                   user_id: agent.id).tap { |p| p.save!(validate: false) }
    end

    it 'привязывает собственника к объекту' do
      user = create(:user, role: :client)

      expect(described_class.attach!(property, user)).to be true
      expect(property.reload.owner_user_id).to eq(user.id)
    end

    # Существующий собственник не перетирается: связь ставится однажды и
    # правится человеком, а не повторным прогоном синхронизации.
    it 'не перетирает уже установленного собственника' do
      first = create(:user, role: :client)
      second = create(:user, role: :client)
      described_class.attach!(property, first)

      expect(described_class.attach!(property, second)).to be false
      expect(property.reload.owner_user_id).to eq(first.id)
    end
  end
end
