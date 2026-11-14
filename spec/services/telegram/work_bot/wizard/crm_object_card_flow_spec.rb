# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telegram::WorkBot::Wizard::CrmObjectCardFlow do
  include_context 'wizard DM harness'

  before { stub_crm_positions }

  let!(:agent) { crm_staff(tg_user_id: 98_971, username: 'irina') }

  it 'меню показывает «Новый объект» только тем, кому CRM разрешает заводить объекты' do
    intern = crm_staff(tg_user_id: 98_972, username: 'intern', position: '89878')
    labels = ->(user) { Telegram::WorkBot::Wizard::Menu.keyboard(user).flatten.map { |b| b[:text] } }

    expect(labels.call(agent)).to include('🏠 Новый объект в CRM')
    expect(labels.call(intern)).not_to include('🏠 Новый объект в CRM')
  end

  it 'квартира по агентскому договору: спрашивает площадь, комнаты и номер договора, участок — нет' do
    tap_callback('wiz:s:crm_object', user: agent)
    expect(last_text).to include('Вставь данные объекта')

    press('Заполню по шагам', user: agent)
    expect(last_text).to include('Собственник?')

    say('Иванов Пётр', user: agent)
    say('+7 910 000-11-22', user: agent)
    press('Продажа', user: agent)
    press('Квартира', user: agent)
    say('Рязань, ул. Есенина, 29', user: agent)
    say('5 500 000', user: agent)
    expect(last_text).to include('Общая площадь, м²?')

    say('54,3', user: agent)
    expect(last_text).to include('Комнат?')

    say('2', user: agent)
    press('Агентский', user: agent)
    expect(last_text).to include('Номер договора?')

    say('А-17/26', user: agent)
    expect { press('Сохранить', user: agent) }.to change(CrmCard.kind_object, :count).by(1)

    card = CrmCard.kind_object.last
    expect(card.author).to eq(agent)
    expect(card.payload).to include('owner_phone' => '79100001122', 'price' => 5_500_000, 'area_common' => 54.3,
                                    'rooms' => 2, 'contract_number' => 'А-17/26')
    expect(card.payload).not_to have_key('area_land')
    expect(last_text).to include('Объект в CRM', '✅ пройдена')
  end

  it 'стажёру без права на объекты мастер отказывает до первого вопроса' do
    intern = crm_staff(tg_user_id: 98_973, username: 'intern', position: '89878')

    tap_callback('wiz:s:crm_object', user: intern)

    expect(last_text).to include('право заводить объекты')
    expect(CrmCard.count).to eq(0)
  end
end
