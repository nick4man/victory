# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Commands::Objections do
  let(:tg_client) { instance_double(Telegram::Client, send_message: { 'message_id' => 1 }) }
  let(:agent)    { TelegramUser.create!(tg_user_id: 111, role: 'agent', first_name: 'Ирина', status: 'active', dm_chat_id: 111) }
  let(:director) { TelegramUser.create!(tg_user_id: 333, role: 'director', first_name: 'Оксана', status: 'active') }
  let(:property) { create(:property, address: 'Рязань, ул. Есенина, 12', price: 5_500_000) }
  let!(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'tg_dm', current_stage: 'show', anchor_topic_key: 'apartments',
                      tg_chat_id: -100_1, anchor_message_id: 900, assigned_to: agent, property: property)
  end

  def run(args)
    msg = { 'chat' => { 'id' => 111, 'type' => 'private' }, 'from' => { 'id' => 111 }, 'message_id' => 5, 'text' => "/objections #{args}" }
    described_class.new(message: msg, args: args, tg_user: agent, client: tg_client).send(:handle)
  end

  it 'сводка: количество показов, теги с частотой, исходы, названные цены' do
    2.times do
      ShowReport.create!(lead_event: lead, property: property, conducted_by: director, reported_by: agent, conducted_at: 1.day.ago,
                         source: 'voice', status: 'confirmed', objections: ['маленькая кухня'], outcome: 'thinking')
    end
    ShowReport.create!(lead_event: lead, property: property, conducted_by: director, reported_by: agent, conducted_at: 1.day.ago,
                       source: 'voice', status: 'confirmed', objections: ['первый этаж'], outcome: 'bargain', offered_price: 5_200_000)
    run(lead.id.to_s)
    expect(tg_client).to have_received(:send_message).with(
      a_string_including('Есенина', '3 показ', '2× маленькая кухня', '1× первый этаж', '💬 Торг', '5 200 000'), anything
    )
  end

  it 'без показов — честно так и пишет' do
    run(lead.id.to_s)
    expect(tg_client).to have_received(:send_message).with(a_string_including('пока не было'), anything)
  end

  it 'лид без объекта — считает по лиду' do
    lead.update!(property: nil)
    run(lead.id.to_s)
    expect(tg_client).to have_received(:send_message).with(a_string_including("лид ##{lead.id}"), anything)
  end
end
