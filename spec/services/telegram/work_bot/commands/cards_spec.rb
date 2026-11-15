# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Commands::Cards do
  let(:sent) { [] }
  let(:tg_client) do
    client = instance_double(Telegram::Client)
    allow(client).to receive(:send_message) do |text, **opts|
      sent << { text: text, keyboard: opts.dig(:reply_markup, :inline_keyboard) || [] }
      { 'message_id' => 1 }
    end
    client
  end

  before { stub_crm_positions }

  let!(:agent)    { crm_staff(tg_user_id: 98_951, username: 'irina') }
  let!(:director) { crm_staff(tg_user_id: 98_952, username: 'oksana', position: '89884', role: 'director') }
  let!(:draft)    { CrmCard.create!(kind: 'lead', author: agent, payload: { 'name' => 'Анна' }) }
  let!(:pending) do
    CrmCard.create!(kind: 'lead', author: agent, status: 'pending_review', submitted_at: 1.hour.ago,
                    payload: { 'name' => 'Борис' })
  end
  let!(:failed) { CrmCard.create!(kind: 'object', author: agent, status: 'export_failed', payload: { 'owner_name' => 'Вера' }) }

  def run(user, chat_type: 'private')
    message = { 'chat' => { 'id' => user.tg_user_id, 'type' => chat_type }, 'from' => { 'id' => user.tg_user_id },
                'message_id' => 5, 'text' => '/cards' }
    described_class.new(message: message, args: '', tg_user: user, client: tg_client).call
  end

  it 'сотруднику — все свои карточки в работе (и на модерации), чужих нет, выгруженных нет' do
    other = crm_staff(tg_user_id: 98_953, username: 'petr')
    CrmCard.create!(kind: 'object', author: other, payload: { 'owner_name' => 'Жанна' })
    CrmCard.create!(kind: 'object', author: agent, status: 'exported', crm_id: '77', payload: { 'owner_name' => 'Олег' })

    run(agent)

    expect(sent.last[:text]).to include('Анна', 'Борис', 'Вера').and(satisfy { |t| !t.include?('Жанна') && !t.include?('Олег') })
    expect(sent.last[:keyboard].flatten.map { |b| b[:callback_data] })
      .to contain_exactly("crm_card:#{draft.id}:view", "crm_card:#{pending.id}:view", "crm_card:#{failed.id}:view")
  end

  it 'длинная очередь — в заголовке полное число' do
    12.times { |i| CrmCard.create!(kind: 'object', author: agent, status: 'pending_review', payload: { 'owner_name' => "К#{i}" }) }

    run(director)

    expect(sent.last[:text]).to include('⏳ На модерации</b> (10 из 13)')
  end

  it 'одобренный объект ждёт внесения — виден ответственному, пока номер не отмечен' do
    approved = CrmCard.create!(kind: 'object', author: agent, status: 'approved', payload: { 'owner_name' => 'Глеб' })

    run(agent)

    expect(sent.last[:text]).to include('Глеб')
    expect(sent.last[:keyboard].flatten.map { |b| b[:callback_data] }).to include("crm_card:#{approved.id}:view")
  end

  it 'модератору — ещё очередь модерации и сбои выгрузки' do
    run(director)

    expect(sent.last[:text]).to include('⏳ На модерации', 'Борис', '⚠️ Сбои выгрузки', 'Вера')
    expect(sent.last[:keyboard].flatten.map { |b| b[:callback_data] })
      .to include("crm_card:#{pending.id}:view", "crm_card:#{failed.id}:view")
  end

  it 'в группе список не показывает: там имена клиентов' do
    run(agent, chat_type: 'supergroup')

    expect(sent.last[:text]).to include('только в личке')
    expect(sent.last[:text]).not_to include('Анна')
  end
end
