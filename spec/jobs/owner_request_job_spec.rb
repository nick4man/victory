# frozen_string_literal: true

require 'rails_helper'

RSpec.describe OwnerRequestJob do
  let(:tg_client) { instance_double(Telegram::Client, send_message: { 'message_id' => 1 }) }

  before { allow(Telegram::Client).to receive(:new).and_return(tg_client) }

  def tg_account(tg_user_id:, dm_chat_id: 555, status: 'active')
    TelegramUser.create!(tg_user_id: tg_user_id, tg_username: "u#{tg_user_id}",
                         first_name: 'Агент', role: 'agent',
                         status: status, dm_chat_id: dm_chat_id)
  end

  def agent_with_tg(**opts)
    create(:user, role: :agent, telegram_user: tg_account(**opts))
  end

  def property_for(agent, **attrs)
    Property.new({ title: 'Объект', price: 5_000_000, address: 'Рязань, ул. Ленина',
                   user_id: agent.id }.merge(attrs)).tap { |p| p.save!(validate: false) }
  end

  describe 'кому и сколько шлём' do
    # Главное свойство: у агента может быть 44 таких объекта, но за прогон он
    # получает ровно один вопрос. Иначе бота замьютят вместе с заявками.
    it 'спрашивает про один объект за прогон, даже если их много' do
      agent = agent_with_tg(tg_user_id: 900_201)
      3.times { property_for(agent) }

      expect(described_class.new.perform).to include(sent: 1)
      expect(tg_client).to have_received(:send_message).once
    end

    it 'шлёт каждому достижимому агенту' do
      a1 = agent_with_tg(tg_user_id: 900_202)
      a2 = agent_with_tg(tg_user_id: 900_203, dm_chat_id: 556)
      property_for(a1)
      property_for(a2)

      expect(described_class.new.perform).to include(sent: 2)
    end

    it 'помечает объект отправленным' do
      agent = agent_with_tg(tg_user_id: 900_204)
      property = property_for(agent)

      described_class.new.perform

      expect(property.reload.owner_request_sent_at).to be_present
    end
  end

  describe 'кого пропускаем' do
    it 'молчит, когда личка не открыта' do
      agent = agent_with_tg(tg_user_id: 900_205, dm_chat_id: nil)
      property_for(agent)

      expect(described_class.new.perform).to include(sent: 0, skipped_unreachable: 1)
      expect(tg_client).not_to have_received(:send_message)
    end

    it 'молчит, когда агент не связан с телеграмом' do
      agent = create(:user, role: :agent)
      property_for(agent)

      expect(described_class.new.perform).to include(sent: 0, skipped_unreachable: 1)
    end

    it 'не трогает объекты, у которых собственник уже есть' do
      agent = agent_with_tg(tg_user_id: 900_206)
      owner = create(:user, role: :client)
      property_for(agent, owner_user_id: owner.id)

      expect(described_class.new.perform).to include(sent: 0)
    end

    it 'не спрашивает про отложенные' do
      agent = agent_with_tg(tg_user_id: 900_207)
      property_for(agent, owner_request_snoozed_until: 3.days.from_now)

      expect(described_class.new.perform).to include(sent: 0)
    end

    # «Не мой объект» — ответственный указан неверно, это правится человеком
    # в CRM. Повторный вопрос тому же агенту ничего не изменит.
    it 'не спрашивает про те, от которых агент отказался' do
      agent = agent_with_tg(tg_user_id: 900_208)
      property_for(agent, owner_request_declined_at: 1.hour.ago)

      expect(described_class.new.perform).to include(sent: 0)
    end
  end

  describe 'повторные вопросы' do
    it 'не переспрашивает, пока ждёт ответа' do
      agent = agent_with_tg(tg_user_id: 900_209)
      property_for(agent, owner_request_sent_at: 1.day.ago)
      property_for(agent)

      expect(described_class.new.perform).to include(sent: 0)
    end

    it 'спрашивает снова, когда срок ожидания истёк' do
      agent = agent_with_tg(tg_user_id: 900_210)
      property_for(agent, owner_request_sent_at: 5.days.ago)

      expect(described_class.new.perform).to include(sent: 1)
    end

    it 'возвращается к отложенному, когда отсрочка прошла' do
      agent = agent_with_tg(tg_user_id: 900_211)
      property_for(agent, owner_request_snoozed_until: 1.day.ago)

      expect(described_class.new.perform).to include(sent: 1)
    end
  end

  describe 'содержимое сообщения' do
    it 'даёт три кнопки и называет объект' do
      agent = agent_with_tg(tg_user_id: 900_212)
      property = property_for(agent, district: 'Канищево', area: 54)

      described_class.new.perform

      expect(tg_client).to have_received(:send_message) do |text, opts|
        expect(text).to include("##{property.id}", 'Канищево', 'нет собственника')
        actions = opts[:reply_markup][:inline_keyboard].flatten.map { |b| b[:callback_data] }
        expect(actions).to contain_exactly("owner:contact:#{property.id}",
                                           "owner:snooze:#{property.id}",
                                           "owner:decline:#{property.id}")
      end
    end
  end

  describe 'устойчивость' do
    # Один недоставленный вопрос не должен ронять рассылку остальным.
    it 'продолжает работу, когда отправка одному упала' do
      a1 = agent_with_tg(tg_user_id: 900_213)
      a2 = agent_with_tg(tg_user_id: 900_214, dm_chat_id: 557)
      property_for(a1)
      property_for(a2)
      allow(tg_client).to receive(:send_message).and_raise(StandardError, 'сеть')

      expect { described_class.new.perform }.not_to raise_error
    end
  end
end
