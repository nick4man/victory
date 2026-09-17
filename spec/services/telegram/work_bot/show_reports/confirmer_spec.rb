# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::ShowReports::Confirmer do
  let(:tg_client) { instance_double(Telegram::Client, send_message: { 'message_id' => 505 }) }
  let(:agent)    { TelegramUser.create!(tg_user_id: 111, role: 'agent', first_name: 'Ирина', status: 'active', dm_chat_id: 111) }
  let(:director) { TelegramUser.create!(tg_user_id: 333, role: 'director', first_name: 'Оксана', status: 'active') }
  let(:property) { create(:property, address: 'Рязань, ул. Есенина, 12') }
  let(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'tg_dm', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1, assigned_to: agent, property: property,
                      metadata: { 'name' => 'Анна' })
  end
  let(:report) do
    ShowReport.create!(lead_event: lead, property: property, conducted_by: director, reported_by: agent,
                       conducted_at: Time.zone.parse('2026-09-11 14:00'), source: 'voice', outcome: 'bargain',
                       objections: ['маленькая кухня'], offered_price: 5_200_000, next_step: 'перезвонят в пятницу',
                       owner_message: 'Добрый день! ...', uncertainties: ['не понял этаж'])
  end

  subject(:confirmer) { described_class.new(report: report, client: tg_client) }

  it 'превью содержит адрес, покупателя, показывающего, исход, возражения, цену, дату dd.MM.yy' do
    text = confirmer.preview_text
    expect(text).to include('Есенина', 'Анна', 'Оксана', '💬 Торг', 'маленькая кухня', '11.09.26 14:00')
    expect(text).to include('5 200 000')
    expect(text).to include('не понял этаж')
  end

  it 'клавиатура: сохранить / переключить показывающего / отмена' do
    data = confirmer.keyboard[:inline_keyboard].flatten.map { |b| b[:callback_data] }
    expect(data).to contain_exactly("show_report:#{report.id}:approve",
                                    "show_report:#{report.id}:toggle_conductor",
                                    "show_report:#{report.id}:cancel")
    data.each { |d| expect(d.bytesize).to be <= 64 }
  end

  it '#call шлёт превью в DM и сохраняет message_id' do
    confirmer.call
    expect(tg_client).to have_received(:send_message)
      .with(a_string_including('Подтверди отчёт о показе'), hash_including(chat_id: 111, parse_mode: 'HTML'))
    expect(report.reload.preview_message_id).to eq(505)
    expect(report.preview_chat_id).to eq(111)
  end

  it 'HTML в возражениях экранируется' do
    report.update!(objections: ['<b>кухня</b>'])
    expect(confirmer.preview_text).to include('&lt;b&gt;кухня&lt;/b&gt;')
  end
end
