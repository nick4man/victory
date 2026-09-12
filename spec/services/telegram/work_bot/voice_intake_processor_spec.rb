# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::VoiceIntakeProcessor do
  let(:tg_client) do
    instance_double(Telegram::Client, send_message: { 'message_id' => 10 }, edit_message_text: { 'message_id' => 10 })
  end
  let(:agent)    { TelegramUser.create!(tg_user_id: 111, role: 'agent', first_name: 'Ирина', status: 'active', dm_chat_id: 111) }
  let(:director) { TelegramUser.create!(tg_user_id: 333, role: 'director', first_name: 'Оксана', status: 'active', dm_chat_id: 333) }
  let(:transcription) do
    Telegram::WorkBot::VoiceTranscriber::Result.new(text: 'показ прошёл, кухня не понравилась', confidence: -0.2,
                                                   duration_sec: 5, model: 'stub',
                                                   raw: { 'text' => 'показ прошёл, кухня не понравилась' },
                                                   low_confidence: false, hallucination: false, error: nil)
  end
  let(:intake_ok) { Telegram::WorkBot::ShowReports::Intake::Result.new(ok: true, report: instance_double(ShowReport, id: 7)) }

  before do
    allow(Telegram::WorkBot::VoiceTranscriber).to receive(:call).and_return(transcription)
    allow(Nextcloud::VoiceArchiver).to receive(:call)
  end

  def msg_for(user)
    { 'message_id' => 1, 'chat' => { 'id' => user.dm_chat_id, 'type' => 'private' },
      'from' => { 'id' => user.tg_user_id }, 'voice' => { 'file_id' => 'F1' } }
  end

  it 'агент: голос идёт в ShowReports::Intake без классификации интента' do
    intake = instance_double(Telegram::WorkBot::ShowReports::Intake, call: intake_ok)
    allow(Telegram::WorkBot::ShowReports::Intake).to receive(:new).and_return(intake)
    expect(Telegram::WorkBot::VoiceIntentBranch).not_to receive(:call)

    expect(described_class.new(msg_for(agent), client: tg_client).call).to eq(:show_report)
    expect(Telegram::WorkBot::ShowReports::Intake).to have_received(:new)
      .with(hash_including(reporter: agent, source: 'voice', transcript_raw: 'показ прошёл, кухня не понравилась'))
  end

  it 'директор: интент show_report → Intake' do
    allow(Telegram::WorkBot::VoiceIntentBranch).to receive(:call).and_return(:show_report)
    intake = instance_double(Telegram::WorkBot::ShowReports::Intake, call: intake_ok)
    allow(Telegram::WorkBot::ShowReports::Intake).to receive(:new).and_return(intake)
    expect(described_class.new(msg_for(director), client: tg_client).call).to eq(:show_report)
  end

  it 'Intake вернул ok:false → текст подсказки в edit «Слушаю…»' do
    intake = instance_double(Telegram::WorkBot::ShowReports::Intake,
                             call: Telegram::WorkBot::ShowReports::Intake::Result.new(ok: false, message: '🤔 Не понял лид'))
    allow(Telegram::WorkBot::ShowReports::Intake).to receive(:new).and_return(intake)
    expect(described_class.new(msg_for(agent), client: tg_client).call).to eq(:show_report_failed)
    expect(tg_client).to have_received(:edit_message_text).with(a_string_including('Не понял лид'), hash_including(message_id: 10))
  end

  it 'неактивный сотрудник → отказ' do
    agent.update!(status: 'inactive')
    expect(described_class.new(msg_for(agent), client: tg_client).call).to eq(:refused)
  end

  it 'директор с интентом task_batch и pending TaskBatch → :refused_pending (старое поведение сохранено)' do
    allow(Telegram::WorkBot::VoiceIntentBranch).to receive(:call).and_return(:task_batch)
    TaskBatch.create!(created_by: director, source: 'voice', status: 'pending_confirm', parsed_payload: { 'tasks' => [] })
    expect(described_class.new(msg_for(director), client: tg_client).call).to eq(:refused_pending)
  end
end
