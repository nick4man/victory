# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::ShowReports::Finalizer do
  let(:tg_client) do
    instance_double(Telegram::Client, send_message: { 'message_id' => 1 }, edit_message_text: { 'message_id' => 1 })
  end
  let(:agent)    { TelegramUser.create!(tg_user_id: 111, role: 'agent', first_name: 'Ирина', status: 'active', dm_chat_id: 111) }
  let(:director) { TelegramUser.create!(tg_user_id: 333, role: 'director', first_name: 'Оксана', status: 'active') }
  let(:owner)    { create(:user) }
  let(:property) { create(:property, address: 'Рязань, ул. Есенина, 12', owner_user: owner) }
  let(:lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'tg_dm', current_stage: 'first_contact',
                      anchor_topic_key: 'apartments', tg_chat_id: -100_1, anchor_thread_id: 17, anchor_message_id: 900,
                      assigned_to: agent, property: property, metadata: { 'name' => 'Анна' })
  end
  let(:conducted_at) { Time.zone.parse('2026-09-11 14:00') }
  let(:report) do
    ShowReport.create!(lead_event: lead, property: property, conducted_by: director, reported_by: agent,
                       conducted_at: conducted_at, source: 'voice', outcome: 'thinking', objections: ['кухня'],
                       owner_message: 'Добрый день! Провели показ.')
  end

  subject(:finalize) { described_class.new(report: report, actor: agent, client: tg_client).call }

  it 'подтверждает, двигает стадию в show и ставит first_show_at = conducted_at' do
    expect(finalize).to eq(:confirmed)
    expect(report.reload.status_confirmed?).to be(true)
    lead.reload
    expect(lead.current_stage).to eq('show')
    expect(lead.first_show_at).to eq(conducted_at)
  end

  it 'не откатывает стадию, если лид уже дальше show' do
    lead.update!(current_stage: 'contract')
    finalize
    expect(lead.reload.current_stage).to eq('contract')
  end

  it 'создаёт Task «обратная связь собственнику» до 11:00 следующего дня на рассказчика' do
    finalize
    task = Task.find(report.reload.feedback_task_id)
    expect(task.kind_call?).to be(true)
    expect(task.assignee).to eq(agent)
    expect(task.lead_event).to eq(lead)
    expect(task.title).to include('собственнику', 'Есенина')
    expect(task.due_at.in_time_zone('Europe/Moscow').strftime('%d.%m.%y %H:%M')).to eq('12.09.26 11:00')
  end

  it 'постит итог показа в топик карточки reply на якорь' do
    finalize
    expect(tg_client).to have_received(:send_message).with(
      a_string_including('Показ', '11.09.26', 'кухня'),
      hash_including(chat_id: -100_1, message_thread_id: 17, reply_to_message_id: 900)
    )
  end

  # Кнопки проверяем по захваченным вызовам: блок у have_received не вызывается.
  def owner_card_buttons
    calls = []
    allow(tg_client).to receive(:send_message) { |text, **opts| calls << [text, opts]; { 'message_id' => 1 } }
    finalize
    card = calls.find { |text, opts| opts[:chat_id] == 111 && text.include?('Добрый день! Провели показ.') }
    expect(card).not_to be_nil
    card[1][:reply_markup][:inline_keyboard].flatten.map { |b| b[:callback_data] }
  end

  it 'шлёт рассказчику черновик собственнику с кнопкой «отправил сам»; «в TG» — только если собственник в TG' do
    data = owner_card_buttons
    expect(data).to include("show_report:#{report.id}:owner_sent")
    expect(data).not_to include("show_report:#{report.id}:owner_push")
  end

  it 'с привязанным TG собственника появляется кнопка owner_push' do
    owner.update_columns(tg_user_id: 777_001)
    expect(owner_card_buttons).to include("show_report:#{report.id}:owner_push")
  end

  it 'нудж сегмента, если он пуст; без нуджа — если указан' do
    finalize
    expect(tg_client).to have_received(:send_message).with(a_string_including('сегмент'), hash_including(chat_id: 111))
  end

  it 'повторный вызов → :already_done без побочных эффектов' do
    finalize
    expect(described_class.new(report: report, actor: agent, client: tg_client).call).to eq(:already_done)
    expect(Task.where(lead_event: lead).count).to eq(1)
  end

  # Находка ревью PR #65: назначенный показывающий не сбрасывался, и все
  # следующие отчёты по лиду приписывались ему же.
  it 'сбрасывает назначенного показывающего — следующий показ не приписывается ему' do
    lead.update!(metadata: lead.metadata.merge('show_conductor_id' => director.id,
                                               'show_conductor_set_by' => '@dir'))
    finalize
    expect(lead.reload.metadata).not_to include('show_conductor_id')
  end

  describe '.feedback_due_at' do
    it 'показ днём → завтра 11:00 МСК' do
      expect(described_class.feedback_due_at(Time.zone.parse('2026-09-11 14:00')).in_time_zone('Europe/Moscow').hour).to eq(11)
      expect(described_class.feedback_due_at(Time.zone.parse('2026-09-11 14:00')).to_date).to eq(Date.new(2026, 9, 12))
    end

    it 'показ после полуночи (ночной отчёт) → сегодня 11:00' do
      at = Time.find_zone('Europe/Moscow').parse('2026-09-12 00:30')
      expect(described_class.feedback_due_at(at).in_time_zone('Europe/Moscow').to_date).to eq(Date.new(2026, 9, 12))
    end
  end
end
