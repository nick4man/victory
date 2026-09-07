# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Callbacks::LinkStaffCallback do
  let!(:director) do
    TelegramUser.create!(tg_user_id: 120_001, tg_username: 'oks', first_name: 'Оксана',
                         role: 'director', is_manager: true, status: 'active',
                         dm_chat_id: 120_001)
  end

  # Аккаунт без связи и с открытой личкой — типовой кандидат на связывание.
  let!(:unlinked_tg) do
    TelegramUser.create!(tg_user_id: 900_101, tg_username: 'nadya', first_name: 'Надежда',
                         role: 'agent', status: 'active', dm_chat_id: 900_101)
  end

  let!(:agent_user) { create(:user, role: :agent, first_name: 'Надежда', last_name: 'Синицына') }

  let(:tg_client) do
    instance_double(Telegram::Client, send_message: { 'message_id' => 1 },
                                      answer_callback_query: { 'ok' => true })
  end

  def build_cb(data)
    { 'id' => 'cb_1', 'from' => { 'id' => director.tg_user_id }, 'data' => data,
      'message' => { 'message_id' => 5, 'chat' => { 'id' => director.tg_user_id, 'type' => 'private' } } }
  end

  def invoke(data, args, actor: director)
    described_class.new(callback_query: build_cb(data), tg_user: actor, args: args,
                        client: tg_client).call
  end

  describe 'список несвязанных' do
    it 'показывает кнопку на каждый несвязанный аккаунт' do
      invoke('link_staff', [])
      expect(tg_client).to have_received(:send_message).with(
        a_string_matching(/Кого связать/),
        hash_including(reply_markup: a_hash_including(:inline_keyboard))
      )
    end

    # Связанный аккаунт уходит из списка, но список не обязан пустеть: сам
    # директор — тоже сотрудник, и его аккаунт связывать надо. На проде это
    # ровно случай Оксаны, чей телеграм не сопоставлен с учёткой в CRM.
    it 'убирает из списка тех, кто уже связан' do
      agent_user.update_column(:telegram_user_id, unlinked_tg.id)
      invoke('link_staff', [])

      expect(tg_client).to have_received(:send_message) do |_text, opts|
        payload = opts[:reply_markup][:inline_keyboard].flatten.map { |b| b[:callback_data] }
        expect(payload).not_to include("link_staff:tg:#{unlinked_tg.id}")
      end
    end

    it 'сообщает, когда связывать некого' do
      agent_user.update_column(:telegram_user_id, unlinked_tg.id)
      director.update_column(:status, 'inactive')
      invoke('link_staff', [])

      expect(tg_client).to have_received(:send_message).with(
        a_string_matching(/уже связаны/), any_args
      )
    end
  end

  describe 'связывание' do
    it 'проставляет связь' do
      invoke("link_staff:do:#{unlinked_tg.id}:#{agent_user.id}", ['do', unlinked_tg.id.to_s, agent_user.id.to_s])
      expect(agent_user.reload.telegram_user_id).to eq(unlinked_tg.id)
    end

    # Связь установлена, но если личка закрыта — рассылка всё равно не сработает.
    # Директор должен узнать об этом сразу, а не через неделю молчания бота.
    it 'предупреждает, когда личка не открыта' do
      unlinked_tg.update_column(:dm_chat_id, nil)
      invoke("link_staff:do:#{unlinked_tg.id}:#{agent_user.id}", ['do', unlinked_tg.id.to_s, agent_user.id.to_s])
      expect(tg_client).to have_received(:send_message).with(
        a_string_matching(/написать боту первым/), any_args
      )
    end

    it 'не связывает второго сотрудника с тем же телеграмом' do
      other = create(:user, role: :agent)
      other.update_column(:telegram_user_id, unlinked_tg.id)

      invoke("link_staff:do:#{unlinked_tg.id}:#{agent_user.id}", ['do', unlinked_tg.id.to_s, agent_user.id.to_s])

      expect(agent_user.reload.telegram_user_id).to be_nil
      expect(tg_client).to have_received(:answer_callback_query)
        .with('cb_1', hash_including(text: a_string_matching(/уже связан/)))
    end

    it 'не связывает сотрудника, у которого уже есть телеграм' do
      another_tg = TelegramUser.create!(tg_user_id: 900_102, tg_username: 'dup',
                                        role: 'agent', status: 'active')
      agent_user.update_column(:telegram_user_id, another_tg.id)

      invoke("link_staff:do:#{unlinked_tg.id}:#{agent_user.id}", ['do', unlinked_tg.id.to_s, agent_user.id.to_s])

      expect(agent_user.reload.telegram_user_id).to eq(another_tg.id)
    end
  end

  describe 'отчёт о достижимости' do
    it 'перечисляет причины, по которым бот не сможет написать' do
      create(:user, role: :agent, first_name: 'Без', last_name: 'Телеграма')
      invoke('link_staff:report', ['report'])
      expect(tg_client).to have_received(:send_message).with(
        a_string_matching(/Достижимость сотрудников/), any_args
      )
    end
  end

  describe 'права' do
    it 'не пускает не-директора' do
      agent_tg = TelegramUser.create!(tg_user_id: 900_103, tg_username: 'plain',
                                      role: 'agent', status: 'active')
      invoke('link_staff', [], actor: agent_tg)

      expect(tg_client).not_to have_received(:send_message)
      expect(tg_client).to have_received(:answer_callback_query)
        .with('cb_1', hash_including(show_alert: true))
    end
  end
end
