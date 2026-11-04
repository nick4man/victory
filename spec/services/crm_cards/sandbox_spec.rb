# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'песочница карточек CRM (тестовый бот)' do
  let(:notifier) do
    instance_double(CrmCards::Notifier, submitted: nil, returned: nil, approved: nil, released: nil, exported: nil, export_failed: nil)
  end
  let(:workflow) { CrmCards::Workflow.new(notifier: notifier) }

  before { stub_crm_positions }

  let!(:agent)    { crm_staff(tg_user_id: 99_101, username: 'irina') }
  let!(:director) { crm_staff(tg_user_id: 99_102, username: 'oksana', position: '89884', role: 'director') }
  let!(:nick) { TelegramUser.create!(tg_user_id: 99_103, tg_username: 'nick', status: 'active', dm_chat_id: 99_103) }
  let(:test_lead) do
    LeadEvent.create!(lead_ref: agent, source: 'manual', current_stage: 'first_contact', first_contact_at: 1.hour.ago,
                      anchor_topic_key: 'dispatcher', tg_chat_id: agent.dm_chat_id, assigned_to: agent, staff_test: true,
                      metadata: { 'sandbox' => true })
  end
  let(:real_lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'first_contact',
                      first_contact_at: 1.hour.ago, anchor_topic_key: 'apartments', tg_chat_id: -100_1, assigned_to: agent)
  end
  let(:values) do
    { 'name' => 'Тест', 'phone' => '79101234567', 'action' => 'sale', 'object_type' => 'flat',
      'comment' => 'Проверка песочницы: весь путь без записи в CRM' }
  end

  def in_test(&)
    Telegram::BotContext.within('test', &)
  end

  describe 'права' do
    before do
      stub_const('ENV', ENV.to_h.merge('TELEGRAM_TEST_CAPABILITIES' => { '99103' => %w[create_lead moderate] }.to_json))
    end

    it 'список из ENV действует только в тестовом боте' do
      expect(CrmCards::Permissions.for(nick).can?(:moderate)).to be(false)
      in_test { expect(CrmCards::Permissions.for(nick).can?(:moderate)).to be(true) }
    end

    it 'в песочнице модераторы — и по CRM, и по списку' do
      in_test { expect(CrmCards::Permissions.moderators).to contain_exactly(director, nick) }
      expect(CrmCards::Permissions.moderators).to eq([director])
    end
  end

  describe 'кривой TELEGRAM_TEST_CAPABILITIES' do
    it 'не JSON — пустые права, без падения' do
      stub_const('ENV', ENV.to_h.merge('TELEGRAM_TEST_CAPABILITIES' => 'not json'))

      in_test { expect(CrmCards::Permissions.sandbox_capabilities).to eq({}) }
    end

    it 'валидный JSON, но не объект ("[]") — пустые права, без падения' do
      stub_const('ENV', ENV.to_h.merge('TELEGRAM_TEST_CAPABILITIES' => '[]'))

      in_test { expect(CrmCards::Permissions.sandbox_capabilities).to eq({}) }
    end
  end

  it 'в тестовом боте карточку по реальному лиду не завести' do
    in_test do
      expect(workflow.upsert_lead_card!(lead: real_lead, actor: agent, values: values).error).to include('тестовым лидам')
    end
    expect(CrmCard.unscoped.count).to eq(0)
  end

  it 'рабочий бот не заводит карточку по тестовому лиду, а клиент с «именем сотрудника» — не тестовый' do
    expect(workflow.upsert_lead_card!(lead: test_lead, actor: agent, values: values).error).to include('песочницы')

    real_lead.update!(staff_test: true, staff_test_matched_by: 'name_staff_first')
    in_test do
      expect(workflow.upsert_lead_card!(lead: real_lead, actor: agent, values: values).error).to include('тестовым лидам')
    end
  end

  it 'весь путь в песочнице: TEST-номер, в Topnlab ни одного вызова' do
    allow(Topnlab::Client).to receive(:new)

    card = in_test { workflow.upsert_lead_card!(lead: test_lead, actor: agent, values: values).card }
    expect(card).to be_sandbox
    expect(card.check_passed?).to be(true)

    in_test do
      workflow.submit!(card, actor: agent)
      workflow.approve!(card.reload, actor: director)
      workflow.release_for_export!(card.reload, actor: director)
    end
    CrmCards::ExportJob.perform_now(card.id)

    expect(card.reload).to have_attributes(status: 'exported', crm_id: "TEST-#{card.id}")
    expect(Topnlab::Client).not_to have_received(:new)
  end

  it 'номер объекта из песочницы не запирает тот же номер в рабочем боте' do
    staff = crm_staff(tg_user_id: 98_991, username: 'sbx_obj')
    CrmCard.create!(kind: 'object', author: staff, status: 'exported', export_mode: 'manual', crm_id: '123456',
                    sandbox: true, payload: { 'owner_name' => 'Тест' })
    real = CrmCard.create!(kind: 'object', author: staff, status: 'approved', payload: { 'owner_name' => 'Настоящий' })
    flow = Telegram::WorkBot::Wizard::CrmCardManualExportFlow.new(
      tg_user: staff, ctx: { 'card' => real.id.to_s }, client: instance_double(Telegram::Client)
    )

    expect(flow.send(:number_taken_by, '123456')).to be_nil
    expect(in_test { flow.send(:number_taken_by, '123456') }).to include('уже отмечен')
  end

  it 'карточка живёт в своём боте' do
    card = in_test { workflow.upsert_lead_card!(lead: test_lead, actor: agent, values: values).card }

    expect(CrmCard.in_current_bot).not_to include(card)
    expect(workflow.update_fields!(card, { 'name' => 'Другое' }, actor: agent).error).to include('тестового бота')
    in_test { expect(CrmCard.in_current_bot).to include(card) }
  end

  it 'машинная проверка песочницы не пропускает реальный лид, даже если карточка уже есть' do
    card = CrmCard.create!(kind: 'lead', author: agent, lead_event: real_lead, sandbox: true, payload: values)

    expect(CrmCards::Checker.call(card).map { |e| e['message'] }).to include('В песочнице — только тестовые лиды.')
  end

  it 'джоб выгрузки ставит контекст по карточке, а не по очереди' do
    card = CrmCard.create!(kind: 'lead', author: agent, lead_event: test_lead, sandbox: true, status: 'approved')
    seen = nil
    allow(CrmCards::Workflow).to receive(:new) do
      seen = Telegram::BotContext.bot
      instance_double(CrmCards::Workflow, export!: nil)
    end

    CrmCards::ExportJob.perform_now(card.id)

    expect(seen).to eq('test')
  end
end
