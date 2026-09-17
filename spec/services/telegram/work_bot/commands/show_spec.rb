# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Commands::Show do
  let(:tg_client) { instance_double(Telegram::Client, send_message: { 'message_id' => 1 }) }
  let(:agent) { TelegramUser.create!(tg_user_id: 111, role: 'agent', first_name: 'Ирина', status: 'active', dm_chat_id: 111) }
  let!(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'tg_dm', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1, anchor_message_id: 900, assigned_to: agent)
  end
  let(:intake) { instance_double(Telegram::WorkBot::ShowReports::Intake) }

  before { allow(Telegram::WorkBot::ShowReports::Intake).to receive(:new).and_return(intake) }

  def run(args, msg_overrides = {})
    msg = { 'chat' => { 'id' => 111, 'type' => 'private' }, 'from' => { 'id' => 111 }, 'message_id' => 5,
            'text' => "/show #{args}" }.merge(msg_overrides)
    described_class.new(message: msg, args: args, tg_user: agent, client: tg_client).send(:handle)
  end

  it '/show <id> <текст> → Intake с явным лидом и source text; текст маскируется' do
    allow(intake).to receive(:call).and_return(Telegram::WorkBot::ShowReports::Intake::Result.new(ok: true))
    run("#{lead.id} показ прошёл, звонить +79001234567")
    expect(Telegram::WorkBot::ShowReports::Intake).to have_received(:new).with(
      hash_including(lead: lead, source: 'text', reporter: agent,
                     transcript_raw: 'показ прошёл, звонить +79001234567',
                     transcript_redacted: satisfy { |s| !s.include?('79001234567') })
    )
  end

  it 'reply на карточку без id тоже работает' do
    allow(intake).to receive(:call).and_return(Telegram::WorkBot::ShowReports::Intake::Result.new(ok: true))
    run('кухня не понравилась', 'chat' => { 'id' => -100_1, 'type' => 'supergroup' }, 'reply_to_message' => { 'message_id' => 900 })
    expect(Telegram::WorkBot::ShowReports::Intake).to have_received(:new).with(hash_including(lead: lead))
  end

  it 'без текста — формат' do
    run(lead.id.to_s)
    expect(tg_client).to have_received(:send_message).with(a_string_including('Формат'), anything)
    expect(Telegram::WorkBot::ShowReports::Intake).not_to have_received(:new)
  end

  it 'Intake ok:false → его сообщение в ответ' do
    allow(intake).to receive(:call).and_return(Telegram::WorkBot::ShowReports::Intake::Result.new(ok: false, message: 'неподтверждённый #3'))
    run("#{lead.id} текст отчёта")
    expect(tg_client).to have_received(:send_message).with(a_string_including('неподтверждённый #3'), anything)
  end
end
