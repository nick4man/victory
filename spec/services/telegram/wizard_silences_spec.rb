# frozen_string_literal: true

require 'rails_helper'

# Два молчания из QA-прогона 20.09.26: ответ в протухший мастер и стикер
# посреди шага уходили в никуда, и человек не понимал, жив ли бот.
RSpec.describe 'мастер не молчит на неожиданный ввод' do
  let!(:staff) do
    TelegramUser.create!(tg_user_id: 97_001, tg_username: 'irina', status: 'active',
                         dm_chat_id: 97_001, topnlab_user_id: 555, role: 'agent')
  end
  let(:sent) { [] }

  before do
    allow_any_instance_of(Telegram::Client).to receive(:send_message) do |_c, text, **opts|
      sent << { text: text, chat_id: opts[:chat_id] }
      { 'message_id' => sent.size }
    end
  end

  def process(message)
    Telegram::InboundProcessor.new({ 'update_id' => rand(1_000_000), 'message' => message }).call
  end

  def dm(extra) = { 'chat' => { 'id' => 97_001, 'type' => 'private' }, 'from' => { 'id' => 97_001 } }.merge(extra)

  it 'ответ в истёкший мастер: бот объясняет, а не молчит' do
    staff.set_pending_action!(type: 'wizard', data: { 'flow' => 'crm_lead', 'bot' => 'main' },
                              step: 'name', ttl: 1.second)
    travel_to(2.minutes.from_now) do
      expect(process(dm('text' => 'Анна Смирнова'))).to eq(:handled)
    end

    expect(sent.last[:text]).to include('Мастер истёк', '/menu')
  end

  it 'про истёкший мастер говорим один раз — след одноразовый' do
    staff.set_pending_action!(type: 'wizard', data: { 'flow' => 'crm_lead', 'bot' => 'main' },
                              step: 'name', ttl: 1.second)
    travel_to(2.minutes.from_now) do
      process(dm('text' => 'Анна Смирнова'))

      expect(staff.reload.expired_action).to be_nil
      expect(Telegram::WorkBot::Wizard::Engine.expired_notice(staff.reload)).to be_nil
    end
  end

  it 'чужой след (фото-режим) мастер не забирает' do
    staff.set_pending_action!(type: 'photo_disposition', data: {}, step: 'describe_task', ttl: 1.second)
    travel_to(2.minutes.from_now) do
      staff.pending_action # протухло — след остался

      expect(Telegram::WorkBot::Wizard::Engine.expired_notice(staff.reload)).to be_nil
      expect(staff.reload.expired_action).to be_present
    end
  end

  it 'стикер посреди шага: понятный отказ, шаг не сброшен' do
    staff.set_pending_action!(type: 'wizard', data: { 'flow' => 'crm_lead', 'bot' => 'main' }, step: 'name')

    expect(process(dm('sticker' => { 'file_id' => 'abc' }))).to eq(:handled)
    expect(sent.last[:text]).to include('ждёт текстовый ответ, а не стикер', 'Шаг не сброшен')
    expect(staff.reload.pending_action).to be_present
  end

  it 'фото посреди шага: отказ, а не тишина' do
    staff.set_pending_action!(type: 'wizard', data: { 'flow' => 'crm_lead', 'bot' => 'main' }, step: 'name')

    expect(process(dm('photo' => [{ 'file_id' => 'abc' }]))).to eq(:handled)
    expect(sent.last[:text]).to include('фото к карточке пока не прикрепляются')
  end

  it 'без мастера вложение перехватывать нечего' do
    expect(process(dm('sticker' => { 'file_id' => 'abc' }))).not_to eq(:handled)
  end
end
