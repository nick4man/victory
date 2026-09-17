# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'карточка заявки из лички и тестовый лид' do
  include_context 'wizard DM harness'

  before { stub_crm_positions }

  let!(:agent) { crm_staff(tg_user_id: 99_201, username: 'irina') }
  let!(:real_lead) do
    LeadEvent.create!(lead_ref: create(:inquiry), source: 'site_form', current_stage: 'first_contact',
                      first_contact_at: 1.hour.ago, anchor_topic_key: 'apartments', tg_chat_id: -100_1,
                      assigned_to: agent, metadata: { 'name' => 'Анна Реальная' })
  end
  let!(:test_lead) do
    LeadEvent.create!(lead_ref: agent, source: 'manual', current_stage: 'first_contact', first_contact_at: 1.hour.ago,
                      anchor_topic_key: 'dispatcher', tg_chat_id: agent.dm_chat_id, assigned_to: agent, staff_test: true,
                      metadata: { 'name' => 'Тест Тестович', 'sandbox' => true })
  end

  def labels
    dms.last[:keyboard].flatten.map { |b| b[:text] }
  end

  it 'в рабочем боте: из меню — список своих реальных лидов, выбор ведёт к полям' do
    tap_callback('wiz:s:crm_lead', user: agent)

    expect(last_text).to include('По какому лиду карточка?')
    expect(labels.join).to include('Анна').and(satisfy { |t| !t.include?('Тест Тестович') })

    press('Анна', user: agent)
    press('Заполню по шагам', user: agent)
    expect(last_text).to include('Телефон?') # имя пришло с лидом, телефона в нём нет
  end

  it 'в тестовом боте: в списке только тестовые лиды' do
    Telegram::BotContext.within('test') { tap_callback('wiz:s:crm_lead', user: agent) }

    expect(labels.join).to include('Тест').and(satisfy { |t| !t.include?('Анна') })
  end

  it 'тестовый лид: создаётся без Inquiry и без сообщений в группу, назначен на себя' do
    Telegram::BotContext.within('test') do
      tap_callback('wiz:s:crm_test_lead', user: agent)
      say('Пётр Проверкин', user: agent)
      say('+7 910 555-00-11', user: agent)
      expect { press('Создать', user: agent) }.to change(LeadEvent.where(staff_test: true), :count).by(1)
    end

    lead = LeadEvent.order(:id).last
    expect(lead).to have_attributes(assigned_to_id: agent.id, current_stage: 'first_contact', source: 'manual')
    expect(lead.metadata).to include('name' => 'Пётр Проверкин', 'phone' => '79105550011', 'sandbox' => true)
    expect(dms.map { |m| m[:chat_id] }).to all(eq(agent.dm_chat_id))
    expect(last_callbacks).to include("wiz:s:crm_lead:#{lead.id}")
  end

  it 'тестовый лид в рабочем боте не заводится' do
    tap_callback('wiz:s:crm_test_lead', user: agent)

    expect(last_text).to include('только в тестовом боте')
  end

  it 'после выбора лида список кандидатов больше не запрашивается на каждом шаге' do
    open_calls = 0
    allow(LeadEvent).to receive(:open).and_wrap_original { |m, *a| open_calls += 1; m.call(*a) }

    tap_callback('wiz:s:crm_lead', user: agent)
    press('Анна', user: agent) # выбор лида — ctx['lead'] ещё не записан на момент поиска шага
    press('Заполню по шагам', user: agent)
    expect(last_text).to include('Телефон?')

    after_pick = open_calls
    expect(after_pick).to be <= 2 # список рендерится + шаг лида один раз ищется, не больше

    say('+7 910 555-00-11', user: agent)
    expect(last_text).to include('Что нужно клиенту?')
    press('Продажа', user: agent)
    expect(last_text).to include('Тип объекта?')
    press('Квартира', user: agent)
    expect(last_text).to include('Итог разговора с клиентом?')

    # После того как лид выбран (ctx['lead'] заполнен), кандидаты больше не
    # запрашиваются ни разу — весь дальнейший путь мастера не бьёт в базу.
    expect(open_calls).to eq(after_pick)
  end

  it 'меню: «Карточка заявки» везде, «Тестовый лид» — только в тестовом боте' do
    main = Telegram::WorkBot::Wizard::Menu.keyboard(agent).flatten.map { |b| b[:text] }
    test = Telegram::BotContext.within('test') { Telegram::WorkBot::Wizard::Menu.keyboard(agent).flatten.map { |b| b[:text] } }

    expect(main).to include('📋 Карточка заявки').and(satisfy { |t| !t.include?('🧪 Тестовый лид') })
    expect(test).to include('📋 Карточка заявки', '🧪 Тестовый лид')
    expect(test).not_to include('📅 Поставить задачу')
  end
end
