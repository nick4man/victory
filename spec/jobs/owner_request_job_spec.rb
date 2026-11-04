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

  # По умолчанию — объект, который действительно претендует на витрину:
  # deal_state='ad' и незакрытый статус. Именно про такие бот и должен
  # спрашивать; закрытые сделки проверяются отдельными примерами ниже.
  def property_for(agent, **attrs)
    Property.new({ title: 'Объект', price: 5_000_000, address: 'Рязань, ул. Ленина',
                   user_id: agent.id, deal_state: 'ad', status: :active }.merge(attrs))
            .tap { |p| p.save!(validate: false) }
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

    # На проде это большинство: 28 закрытых сделок и 37 отложенных против 25
    # живых. Без фильтра `.order(:updated_at)` поднимал бы их наверх — синк их
    # больше не трогает, поэтому они «самые старые», — и первым сообщением
    # агенту приходило бы «объект не попадает на витрину» про проданный в мае
    # участок.
    it 'не спрашивает про закрытые сделки' do
      agent = agent_with_tg(tg_user_id: 900_215)
      property_for(agent, deal_state: 'deal', status: :archived)

      expect(described_class.new.perform).to include(sent: 0)
    end

    it 'не спрашивает про снятые с продажи' do
      agent = agent_with_tg(tg_user_id: 900_216)
      property_for(agent, deal_state: 'deferred', status: :archived)

      expect(described_class.new.perform).to include(sent: 0)
    end

    it 'не спрашивает про проданные, даже если стадия рекламная' do
      agent = agent_with_tg(tg_user_id: 900_217)
      property_for(agent, deal_state: 'ad', status: :sold)

      expect(described_class.new.perform).to include(sent: 0)
    end

    # Прогон 14.08.26: из 25 объектов в очереди 17 уже на витрине. Подпись им
    # проставила миграция при внедрении гейта D5, записи о собственнике при этом
    # не появилось — `owner_user_id` пуст, а карточка открыта на сайте. Агент
    # получал бы «не попадает на витрину» про то, что там уже есть.
    it 'не спрашивает про объекты с подписанным договором' do
      agent = agent_with_tg(tg_user_id: 900_219)
      property_for(agent, deal_state: 'ad', status: :active)
        .update_column(:signed_agency_contract_at, 3.months.ago)

      expect(described_class.new.perform).to include(sent: 0)
    end

    it 'спрашивает про черновик в рекламной стадии' do
      agent = agent_with_tg(tg_user_id: 900_218)
      property_for(agent, deal_state: 'ad', status: :draft)

      expect(described_class.new.perform).to include(sent: 1)
    end

    # Выбор идёт по updated_at, поэтому закрытая сделка не должна «занимать
    # очередь» перед живым объектом того же агента.
    it 'выбирает живой объект, а не давно не обновлявшуюся закрытую сделку' do
      agent = agent_with_tg(tg_user_id: 900_219)
      property_for(agent, deal_state: 'deal', status: :archived, updated_at: 3.months.ago)
      alive = property_for(agent, updated_at: 1.day.ago)

      described_class.new.perform

      expect(alive.reload.owner_request_sent_at).to be_present
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
